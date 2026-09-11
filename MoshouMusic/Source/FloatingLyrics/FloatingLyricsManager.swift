import UIKit

/// 系统级悬浮歌词窗口 — TrollStore 专属能力
///
/// 严格按已真机验证的参考文档实现（TrollSpeed / 墨守提词器方案）：
/// 1. SystemFloatWindow（OC 子类）覆写 _isSystemWindow=YES、
///    _isWindowServerHostingManaged=NO，脱离 WindowServer 托管；
/// 2. dlopen SpringBoardServices 后，把窗口 contextId 注册进 SpringBoard
///    系统窗口树（registerWindowWithContextID:atLevel:）；
/// 3. **窗口本身就是悬浮框大小**（不是全屏窗口 + 内部视图）——
///    窗口只占歌词框那一块，物理上不可能挡住 App 其他区域的触摸；
/// 4. 注册带 0.3s × 4 次重试（contextId 要等下一个 runloop 才生成），
///    成功后绝不再动（反复重注册会让 SpringBoard 移除窗口）；
/// 5. 失败降级为应用内悬浮，设置页展示诊断串。
final class FloatingLyricsManager: NSObject {

    static let shared = FloatingLyricsManager()

    /// 与系统 HUD 同级的窗口层级
    private let windowLevel: CGFloat = 10000010.0

    /// 悬浮窗口本身（尺寸 = 歌词框尺寸）
    private var floatingWindow: FloatingSystemWindow?
    private var lyricsView: FloatingLyricsView?

    private var hostingRegistered = false
    /// v1.0.149：App 前台预览期间跳过 SpringBoard 托管注册
    /// （回退开关：改 false 即恢复「App 内也注册」的旧行为，重影会回来但窗口一定可见）
    private static let skipHostingInAppPreview = true
    private var registerAttempts = 0
    private var lyricsIndex: Int = -1
    private var isLocked = false

    private var pinchStartFrame: CGRect?
    private var pinchStartFont: CGFloat = 16
    private var pinchStartSpan: (x: CGFloat, y: CGFloat)?

    /// v1.0.110：折叠态（滑动收成小圆点，点按展开）
    private var isCollapsed = false
    private var savedExpandedFrame: CGRect?

    /// 是否已成功注册为系统级（跨应用）窗口
    private(set) var isGlobalWindowReady = false
    /// 诊断信息（设置页展示）
    private(set) var lastContextId: UInt32 = 0
    private(set) var hostingClassAvailable = false

    var isShowing: Bool { floatingWindow?.isHidden == false }

    private override init() {
        super.init()
    }

    // MARK: - 显示 / 隐藏

    /// v1.0.121：App 回前台期间悬浮窗整体隐藏（销毁窗口），切到其他应用/桌面再出现
    private var suppressedInApp = false
    /// v1.0.123：悬浮设置页打开期间临时显示（预览模式，其他页面仍隐藏）
    private var settingsPreviewActive = false
    /// v1.0.153：播放页（覆盖全屏模态）打开期间强制隐藏
    private var suppressedByPlayerPage = false

    /// 回前台：销毁系统级窗口（App 内不显示悬浮）
    /// v1.0.123：悬浮设置页打开期间保持显示（实时预览调参效果），不销毁
    func suppressWhileInApp() {
        if settingsPreviewActive {
            // v1.0.149：预览期间窗口保留在 App 内 —— 顺手摘掉 SB 托管（双通道重影根因）
            dropHostingForInApp()
            return
        }
        suppressedInApp = true
        hardRefreshWorkItem?.cancel()
        pulseWorkItem?.cancel()
        teardownWindow()
    }

    /// v1.0.123：悬浮设置页打开 —— 临时显示窗口供实时预览（App 内其他页面仍隐藏）
    func presentForSettings() {
        settingsPreviewActive = true
        suppressedInApp = false
        guard ConfigStore.shared.isFloatingLyricsOn else { return }
        // v1.0.158：灭屏「移出可见区」期间切回设置页预览 → 先归位，
        // 否则预览窗停在屏幕外，用户看到的是「设置页里没有悬浮窗预览」
        if isParkedOffScreen { unparkWindow() }
        Logger.info("悬浮歌词：设置页打开，临时显示窗口供预览")
        show()
        // v1.0.149：App 内预览走单通道渲染（无 SB 托管 = 无拖动重影）
        dropHostingForInApp()
    }

    /// v1.0.123：离开悬浮设置页 —— 恢复 App 内隐藏
    func dismissFromSettings() {
        guard settingsPreviewActive else { return }
        settingsPreviewActive = false
        suppressedInApp = true
        hardRefreshWorkItem?.cancel()
        pulseWorkItem?.cancel()
        teardownWindow()
    }

    /// v1.0.134：熄屏自保的延迟重建任务
    private var selfGuardReshowWork: DispatchWorkItem?

    /// v1.0.155：熄屏自保的阶梯重建档位（秒）。
    /// 拆窗本身必须保留 —— v1.0.132 开关实验坐实「亮屏瞬间后台进程带 SB 托管窗
    /// = 被系统清杀 = 停播」。但重建不必盲等 20s：12s 起先探一次，音频持续健康就提前
    /// 回来；不健康则退回原来的 20s 保守档（最坏情况与 v1.0.148 完全一致）。
    private static let selfGuardReshowDelays: [Double] = [12.0, 20.0]

    /// v1.0.159：**快速档** —— 亮屏后 6s 就尝试重建（让锁屏上尽快看到悬浮窗）。
    /// 依据：用户日志实测「亮屏回调 → 进程被系统强杀」间隔 **2.05s**，6s 有近 3 倍余量；
    /// 而 12s 档历来从未被杀，是已验证过的安全上界。两档走同一个避杀动作（拆窗）。
    private static let selfGuardFastReshowDelays: [Double] = [6.0, 12.0, 20.0]

    /// v1.0.159：当前生效的重建档位 —— 由设置页「锁屏显示悬浮窗」开关选择。
    /// 开（默认）= 快速档（6s 起步）；关 = 保守档（12s 起步）。
    private var activeReshowDelays: [Double] {
        return ConfigStore.shared.isFloatingWakeParkEnabled
            ? FloatingLyricsManager.selfGuardFastReshowDelays
            : FloatingLyricsManager.selfGuardReshowDelays
    }

    /// v1.0.156：亮屏瞬间「移出可见区」的时长（秒）。窗口不销毁、SB 注册不中断，
    /// 归位后锁屏 / 桌面立即可见。取 2.5s 覆盖亮屏后 mediaserverd 的音频仲裁窗口。
    private static let wakeParkSeconds: Double = 2.5

    /// 移出可见区用的位置（只写进 window.frame 这一层显示态，绝不进配置）
    private static let offScreenOrigin = CGPoint(x: -20000, y: -20000)

    /// v1.0.158：灭屏 park 的最长保持时长（秒）—— 亮屏回调万一丢失时的兜底归位
    private static let wakeParkMaxHoldSeconds: Double = 300

    private var isParkedOffScreen = false
    private var parkedOrigin: CGPoint?
    private var parkWork: DispatchWorkItem?

    /// v1.0.158：本次移出可见区是「保持到亮屏」还是「2.5s 后自动归位」
    private var parkHoldsUntilWake = false

    /// v1.0.134 → 156 → 158 → 159：熄屏自保 —— 亮屏瞬间的避杀处理。
    ///
    /// v1.0.132 开关实验坐实：**亮屏瞬间后台进程带 SB 托管窗 = 被系统清杀 = 停播**，
    /// 所以必须在「亮屏那一刻」把窗口从可见区弄走。
    /// v1.0.134~155 的做法是**整条拆掉**（unregister + 销毁），代价是窗口连同 SB 注册
    /// 一起消失，12~20s 后才重建 —— 而锁屏点亮屏幕的那一刻正是这个回调点，于是
    /// **锁屏上基本永远看不到悬浮窗**（用户现象：熄屏点亮之后悬浮窗不见了）。
    ///
    /// v1.0.156 改成二段式判定：
    /// - **灭屏回调**（hasBlankedScreen=1）：什么都不做 —— 屏幕黑着，窗口留着本来就不可见，
    ///   拆了还得重建（顺带消掉「每次屏幕状态变化都触发一次拆/建循环」）；
    /// - **亮屏回调**（hasBlankedScreen=0）：**不拆窗、不重注册**，只把窗口临时移出可见区
    ///   2.5s 再原位移回 —— 锁屏上 2.5s 即见。
    ///
    /// 归位时若音频管线已不健康，兜底退回旧的「拆窗 + 阶梯重建」。
    func screenWakeSelfGuardTeardown() {
        settingsPreviewActive = false
        hardRefreshWorkItem?.cancel()
        pulseWorkItem?.cancel()

        // displayStatus 分不出亮屏还是灭屏 —— 这里补上这一维
        if FloatingWindowHosting.isScreenBlanked() {
            // ✅ v1.0.159 实测定论：**灭屏这一侧是安全的**。
            // 用户日志（锁屏后）：后台心跳连续 40s 正常 —— 位置 5s→15s→25s→35s→45s 稳定推进，
            // 直到 15:23:49 亮屏回调才出事。所以灭屏只需把窗口移出可见区
            //（消掉「随后亮屏那一瞬窗口闪一下」），窗口与 SB 注册都保留。
            parkWindowOffScreen(holdUntilWake: true)
            return
        }

        // 🚨🚨 v1.0.159 根因定论：**亮屏必须「拆除 SB 托管」，移出可见区不够**。
        // v1.0.158 的 park 只把 window.frame 挪到 (-20000,-20000)，
        // accessibility window hosting 会话仍在注册表里 ——
        // 用户日志：亮屏（displayStatus 回调）后 **2.05s 进程即被系统强杀**。
        // ⇒ SpringBoard 清理的是「后台 App 持有的 hosting 会话」本身，与窗口可不可见无关；
        //    v1.0.132「亮屏瞬间带 SB 托管窗 = 被清杀」的结论在「移出可见区」之后**依然成立**。
        // ⇒ 唯一被实测证明能避杀的动作 = unregister（拆窗），也就是 v1.0.134~155 一直在做的事：
        //    那一版用户从未报告「锁屏点亮后被杀」，问题只是重建要等 12~20s 太久。
        //    所以保留拆窗，只把重建提前到 activeReshowDelays 第一档。
        selfGuardReshowWork?.cancel()
        teardownWindow()
        scheduleSelfGuardReshow(attempt: 0)
        Logger.persist("熄屏自保：亮屏瞬间拆除悬浮窗（SB 托管在亮屏时必被清杀），\(Int(activeReshowDelays[0]))s 后开始阶梯重建")
    }

    /// v1.0.156：把窗口**临时移出可见区**（不销毁、不重注册）。
    ///
    /// 🚨 只改 `window.frame`（显示态）。尺寸取配置值、归位取配置里的 origin ——
    /// 绝不把这份临时几何写回配置（v1.0.152 铁律：显示态 ≠ 规范态）。
    private func parkWindowOffScreen(holdUntilWake: Bool = false) {
        guard ConfigStore.shared.isFloatingLyricsOn, !suppressedInApp,
              let window = floatingWindow else { return }
        parkWork?.cancel()
        parkWork = nil
        if !isParkedOffScreen {
            isParkedOffScreen = true
            parkedOrigin = ConfigStore.shared.floatingOrigin
            if holdUntilWake {
                Logger.persist("熄屏自保：灭屏 —— 悬浮窗移出可见区并保持（屏幕黑着不可见；亮屏时另走拆窗避杀）")
            } else {
                Logger.persist("熄屏自保：亮屏瞬间把悬浮窗移出可见区 \(FloatingLyricsManager.wakeParkSeconds)s（保留窗口与 SB 注册，不拆不重注册）")
            }
        }
        applyOffScreenFrame(to: window)
        // v1.0.158：灭屏 park 保持到亮屏回调 —— 屏幕黑着归位没有意义，
        // 只会把窗口重新暴露在「后台 + 可见区」这个高风险组合里。
        // 兜底：万一亮屏回调丢失（hid.displayStatus 未投递），最迟 wakeParkMaxHoldSeconds
        // 后仍自动归位，避免窗口永久停在屏幕外。亮屏回调到来时本 work 会被 cancel 掉。
        parkHoldsUntilWake = holdUntilWake
        let delay: Double = holdUntilWake ? FloatingLyricsManager.wakeParkMaxHoldSeconds : FloatingLyricsManager.wakeParkSeconds
        let work = DispatchWorkItem { [weak self] in self?.unparkWindow() }
        parkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 移出可见区用的几何。用**几何变化**而不是 `isHidden` —— 后者已被证实驱动不了
    /// SB 重合成（窗口纹丝不动留在原地），而大幅位移一定能。
    private func applyOffScreenFrame(to window: FloatingSystemWindow) {
        pulseWorkItem?.cancel()
        window.pulseContentLock = false
        window.layer.removeAllAnimations()
        window.frame = CGRect(origin: FloatingLyricsManager.offScreenOrigin,
                              size: ConfigStore.shared.floatingSize)
    }

    /// 归位：按**配置里的 origin**（规范位置）重建几何，并作废频谱基准
    private func unparkWindow() {
        isParkedOffScreen = false
        parkHoldsUntilWake = false
        guard let window = floatingWindow else { parkedOrigin = nil; return }
        let origin = parkedOrigin ?? ConfigStore.shared.floatingOrigin
        parkedOrigin = nil
        window.pulseContentLock = false
        UIView.performWithoutAnimation {
            window.frame = CGRect(origin: origin, size: ConfigStore.shared.floatingSize)
        }
        window.rootViewController?.view.setNeedsLayout()
        refreshSpectrumBase()
        Logger.persist("熄屏自保：悬浮窗已归位（亮屏后 \(FloatingLyricsManager.wakeParkSeconds)s，锁屏/桌面均可见）")
        // 亮屏确实把管线弄停了 → 退回旧的拆窗重建保护（正常情况下这一步不会走到）
        if !PlayerManager.shared.isPlaybackHealthy {
            Logger.persist("熄屏自保：亮屏后音频不健康，退回拆窗重建保护")
            teardownWindow()
            scheduleSelfGuardReshow(attempt: 0)
        }
    }

    /// v1.0.155：阶梯式后台重建 —— 逐档试探，音频健康即重建；全档不过就放弃本次。
    ///
    /// v1.0.148 的 20s 是「一刀切」：既保护了重建时机，也把窗口回来的时间钉死在 20s。
    /// 拆开成两档后：正常情况 12s 回来，风险情况（音频不健康）自动退到 20s 兜底。
    /// 门禁不变 —— 绝不在「已停播」状态下去注册窗口（v1.0.146/147 的教训）。
    private func scheduleSelfGuardReshow(attempt: Int) {
        let delays = activeReshowDelays
        guard attempt < delays.count else { return }
        let previous = attempt == 0 ? 0 : delays[attempt - 1]
        let interval = delays[attempt] - previous
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.suppressedInApp, ConfigStore.shared.isFloatingLyricsOn else { return }
            guard PlayerManager.shared.isPlaybackHealthy else {
                if attempt + 1 < delays.count {
                    Logger.persist("熄屏自保：音频管线未在播，第 \(attempt + 1) 档跳过，推迟到 \(Int(delays[attempt + 1]))s")
                    self.scheduleSelfGuardReshow(attempt: attempt + 1)
                } else {
                    Logger.persist("熄屏自保：音频管线未在播，跳过本次后台重建（规避注册窗口风险）")
                }
                return
            }
            self.show()
            Logger.persist("熄屏自保：阶梯重建完成（亮屏后 \(Int(delays[attempt]))s，音频健康）")
            // 重建后 6s 存活确认 —— 下次日志能直接区分「重建即死」与「别的原因」
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                Logger.persist("熄屏自保：重建后 6s 存活确认（音频健康=\(PlayerManager.shared.isPlaybackHealthy)）")
            }
        }
        selfGuardReshowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// 离开 App（切其他应用 / 回桌面 / 锁屏）：恢复悬浮窗
    func resumeWhenLeavingApp() {
        if suppressedInApp, ConfigStore.shared.isFloatingLyricsOn {
            suppressedInApp = false
            Logger.info("离开 App：恢复悬浮歌词窗口")
            show()
            return
        }
        // v1.0.149：App 内预览期间窗口未注册 SB 托管 → 离开 App 必须让它变成系统级窗口，
        // 否则切到桌面 / 其他应用后悬浮窗既不可见、更收不到触摸（跨应用操作全靠这份注册）。
        // 只在 App 真正退出活跃态时处理 —— 下拉通知中心 / 控制中心只是瞬时失焦。
        //
        // 🚨 v1.0.151 修正：**绝不就地为同一条窗口补注册**。本项目铁律是「一条窗口只注册
        // 一次」—— 对已经 unregister 过的窗口再 register，SB 会摘掉它的触摸路由：桌面上
        // 悬浮窗照常可见，但完全拖不动（v1.0.149/150 的用户回归正是如此）。
        // 唯一安全做法：销毁旧窗口、重建一条全新窗口再注册（新 contextId = 首次注册）。
        guard ConfigStore.shared.isFloatingLyricsOn,
              UIApplication.shared.applicationState != .active else { return }
        if floatingWindow != nil, !hostingRegistered {
            Logger.info("离开 App：预览窗口重建为系统级窗口（不做同窗重注册）")
            teardownWindow()
            show()
            return
        }
        // v1.0.155：窗口缺失时补建。App 内窗口通常是「拆除态」（前台闸门拒绝显示、
        // 播放页抑制、熄屏自保拆窗后还没到重建档位），此时切到桌面 / 锁屏，桌面上会一直
        // 没有悬浮窗，直到某次换歌触发 hardRefresh 才「突然冒出来」
        //（用户现象：熄屏点亮之后悬浮窗不见了）。
        // 只在真正进入后台（.background）时补建 —— .inactive 会命中「下拉通知中心」这类
        // 瞬时失焦，那种时刻不该凭空造一条系统级窗口出来。
        // ⚠️ 这里【不】加音频健康门禁：门禁是为「亮屏仲裁窗口内不注册窗口」设的
        //（见 scheduleSelfGuardReshow），而「离开 App」是既有的常态建窗路径
        //（上面两个分支也都没有门禁）—— 暂停状态下切桌面同样要能看到窗口才能点恢复。
        guard ConfigStore.shared.isFloatingLyricsOn,
              UIApplication.shared.applicationState == .background,
              floatingWindow == nil else { return }
        Logger.info("离开 App：窗口缺失，补建系统级悬浮窗")
        show()
    }

    /// v1.0.153：播放页（overFullScreen 模态）弹出 —— 该页面覆盖全屏，悬浮窗不应出现在其上。
    /// 与其他 App 内页面走同一条路：拆窗隐藏（不是就地置 hidden）。
    /// 若此刻正处于「悬浮设置页预览」态，也先拆掉，返回设置页时由 restoreAfterPlayerPage 重建。
    func suppressForPlayerPage() {
        suppressedByPlayerPage = true
        hardRefreshWorkItem?.cancel()
        pulseWorkItem?.cancel()
        teardownWindow()
    }

    /// v1.0.153：离开播放页 —— 只有「悬浮设置页预览态」需要把窗口重建回来；
    /// 普通播放路径下 App 仍在前台，窗口本就该隐藏（见 show() 的前台闸门）。
    func restoreAfterPlayerPage() {
        guard suppressedByPlayerPage else { return }
        suppressedByPlayerPage = false
        guard settingsPreviewActive, ConfigStore.shared.isFloatingLyricsOn else { return }
        Logger.info("播放页关闭：恢复悬浮设置页预览窗口")
        show()
    }

    /// 拆除系统级窗口（unregister + 释放，不重建）
    private func teardownWindow() {
        if let window = floatingWindow {
            if hostingRegistered {
                FloatingWindowHosting.unregister(window: window)
                hostingRegistered = false
                isGlobalWindowReady = false
                lastContextId = 0
            }
            // 🚨 v1.0.150：隐藏必须【无条件】执行。v1.0.149 起 App 内会主动摘除 SB 托管
            // （hostingRegistered=false），旧写法把 isHidden 塞在 if 里 → 销毁时窗口没被隐藏，
            // 而 windowScene 会强持有这条 UIWindow → 残留一个「文字不更新、拖不动」的幽灵悬浮窗
            //（floatingWindow 已置 nil：歌词不回填、handlePan 的 guard 直接 return）。
            window.isHidden = true
        }
        floatingWindow = nil
        lyricsView = nil
        registerAttempts = 0
        // v1.0.156：拆窗即作废「移出可见区」状态（否则新窗口会被误判为仍在移出期）
        parkWork?.cancel()
        isParkedOffScreen = false
        parkHoldsUntilWake = false
        parkedOrigin = nil
        purgeOrphanFloatingWindows()
    }

    /// v1.0.150：清理孤儿悬浮窗 —— 引用已丢失、但仍挂在 windowScene 上的
    /// FloatingSystemWindow（v1.0.149 的 teardown 分支缺陷会留下这种窗口）。
    /// windowScene 会强持有 isHidden=false 的窗口，只置 nil 引用是清不掉的。
    private func purgeOrphanFloatingWindows() {
        let orphans = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { $0 is FloatingSystemWindow && $0 !== floatingWindow }
        guard !orphans.isEmpty else { return }
        Logger.persist("清理孤儿悬浮窗 \(orphans.count) 个（引用已丢失但仍挂在 scene 上）")
        for w in orphans {
            w.isHidden = true
            w.windowScene = nil
        }
    }

    func show() {
        guard !suppressedInApp else { return }
        // 🚨 v1.0.153：App 前台且不在悬浮设置页预览态时，系统级窗口一律不得出现在屏幕上。
        // 此前只靠 suppressedInApp 这一份缓存标记，任何漏设/漏清的路径（如播放页这类
        // 全屏模态、scene 回调时序抖动）都会让悬浮窗浮在某个 App 内页面上。这里改成
        // 实时判定，把「App 内不显示」这条不变量钉死在唯一入口上：
        // 离开 App（applicationState != .active）才放行，锁屏/桌面/其他应用依然正常显示。
        if UIApplication.shared.applicationState == .active, !settingsPreviewActive {
            Logger.info("悬浮歌词：App 前台非预览态，拒绝显示系统级窗口")
            return
        }
        if let window = floatingWindow {
            window.isHidden = false
            applySettings()
            registerHostingWithRetry()
            refreshPlaceholder()
            refreshSpectrumState()
            // v1.0.156：仍处于「亮屏移出可见区」期内 → 复用分支也要保持移出
            if isParkedOffScreen { applyOffScreenFrame(to: window) }
            return
        }

        // —— 文档 3.4：窗口就是悬浮框大小 ——
        let frame = CGRect(origin: ConfigStore.shared.floatingOrigin,
                           size: ConfigStore.shared.floatingSize)
        let window = FloatingSystemWindow(frame: frame)
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        window.backgroundColor = .clear
        window.isOpaque = false
        // v1.0.134：熄屏自保延迟重建发生在后台 —— 前台场景不存在时取任意场景兜底
        if let scene = activeScene() ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) {
            window.windowScene = scene
        }

        // 文档第七节：根视图空白区 hitTest 返回 nil，触摸落到下层
        let root = FloatingRootView(frame: window.bounds)
        root.backgroundColor = .clear
        let viewController = UIViewController()
        viewController.view = root
        window.rootViewController = viewController

        let lyricView = FloatingLyricsView(frame: window.bounds,
                                           fontSize: ConfigStore.shared.floatingFontSize)
        // v1.0.123：用配置色（此前写死黑色 → 每次销毁重建后用户选的颜色被重置成黑）
        lyricView.backgroundColor = configuredBgColor()
        lyricView.isUserInteractionEnabled = true
        lyricView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // v1.0.141：折叠圆点封面 + 频谱可见性恢复
        lyricView.setArtwork(PlayerManager.shared.currentArtwork)
        lyricView.setSpectrumVisible(ConfigStore.shared.floatingSpectrumOn)
        root.addSubview(lyricView)

        self.floatingWindow = window
        self.lyricsView = lyricView

        setupGestures()
        // v1.0.154：控制条动作（窗口重建后必须重新绑定 —— 闭包挂在视图上）
        setupControlActions()

        // 让窗口可见但不长期抢占 key（否则会影响输入框等）
        let previousKey = currentKeyWindow()
        window.isHidden = false
        window.makeKeyAndVisible()
        previousKey?.makeKey()

        observeNotifications()
        refreshPlaceholder()
        // v1.0.154：新窗口的中间按钮要立刻反映真实播放状态（不是默认的 pause 图标）
        refreshControlState()

        // contextId 要等下一个 runloop 才生成，注册带重试
        registerHostingWithRetry()
        refreshSpectrumState()
        // v1.0.155：新窗口的频谱基准必须作废重捕。旧基准属于上一条已销毁的窗口，
        // 首帧按它写回几何就会出现日志里那条「悬浮窗高度异常：140pt 超出规范 97pt」
        //（自愈虽在 50ms 内兜住，但会造成重建后一帧的高度抖动）。
        refreshSpectrumBase()
        // v1.0.156：亮屏移出期内的重建，新窗口同样要保持在屏幕外
        if isParkedOffScreen { applyOffScreenFrame(to: window) }
    }

    func hide() {
        // v1.0.151：与 teardownWindow 统一 —— 窗口一旦 unregister 就【绝不再复用】。
        // 旧写法 unregister 后仍保留窗口对象，下次 show() 走复用分支给【同一条窗口】
        // 重新注册，会被 SB 摘掉触摸路由 → 桌面悬浮窗可见但拖不动
        // （与 v1.0.149/150 的桌面拖不动是同一根因）。
        teardownWindow()
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
    }

    private func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: - 系统级窗口注册（注册成功后绝不再动）

    /// v1.0.149：App 前台（设置页预览）期间摘除 SpringBoard 托管，走单通道渲染。
    ///
    /// 🚨 拖动重影根因：窗口 `_isWindowServerHostingManaged = NO`（App 自托管）同时又被
    /// 注册进 SpringBoard accessibility hosting —— App 在前台时同一条窗口被两条路径绘制：
    /// ① App 自己的渲染（立即跟手）；② SB 托管合成（惰性滞后）。拖动时两份位置不同步
    /// = 同一窗口出现两个影像（重影）。桌面 / 其他应用下 App 不渲染，只剩 ② 一条路径，
    /// 所以「桌面拖动没有重影、App 内拖动有重影」。
    func dropHostingForInApp() {
        guard floatingWindow != nil, hostingRegistered else { return }
        // 🚨 v1.0.151：摘托管不能再「就地 unregister + 留下窗口」——
        // 那条窗口之后无论怎么补注册都会被 SB 摘掉触摸路由（桌面可见但拖不动）。
        // 改为「拆掉已注册的窗口，重建一条从未注册过的新窗口」，
        // 让铁律「一条窗口只注册一次」在结构上成立。
        Logger.info("拆除已注册窗口并重建为 App 内单通道窗口（杜绝同窗重注册）")
        teardownWindow()
        show()
    }

    private func registerHostingWithRetry(attempt: Int = 0) {
        guard let window = floatingWindow, !hostingRegistered else { return }
        // v1.0.149：App 前台预览期间不注册 —— 注册即产生双通道（见 dropHostingForInApp）
        if FloatingLyricsManager.skipHostingInAppPreview,
           settingsPreviewActive,
           UIApplication.shared.applicationState == .active {
            Logger.info("悬浮歌词：App 内预览不注册 SB 托管（消除双通道重影）")
            return
        }
        hostingClassAvailable = FloatingWindowHosting.isAvailable()
        registerAttempts = attempt + 1

        if FloatingWindowHosting.register(window: window, level: Double(windowLevel)) {
            hostingRegistered = true
            isGlobalWindowReady = true
            lastContextId = FloatingWindowHosting.contextIdOf(window: window)
            Logger.info("悬浮歌词：已注册系统级窗口(contextId=\(lastContextId))，可跨应用显示")
        } else if attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.registerHostingWithRetry(attempt: attempt + 1)
            }
        } else {
            Logger.warn("悬浮歌词：系统级窗口注册失败(\(hostingClassAvailable))，退化为应用内悬浮")
        }
    }

    /// 设置页展示的一行诊断串
    func diagnosticText() -> String {
        // v1.0.149：App 内预览期间窗口未注册 SB（单通道渲染，防拖动重影）
        if settingsPreviewActive {
            return "状态：App 内预览模式（已摘除 SpringBoard 托管以避免双通道重影），离开 App 后自动注册为系统级窗口。"
        }
        if isGlobalWindowReady {
            return "状态：已注册系统级窗口(contextId=\(lastContextId))，切到其他应用 / 主屏 / 锁屏后依然显示。"
        }
        if ConfigStore.shared.isFloatingLyricsOn {
            let status = hostingClassAvailable ? "类可用但注册未成功(contextId=\(lastContextId))" : "私有类不可用(缺 dlopen 或 entitlement)"
            return "状态：未取得系统级窗口权限（\(status)，尝试 \(registerAttempts) 次）。悬浮歌词仅在应用内可见，需通过 TrollStore 安装以获得权限注入。"
        }
        return "状态：未启用。"
    }

    // MARK: - 设置同步

    /// 设置页改动后立即生效（尺寸 / 字号 / 透明度 / 位置）
    /// 直接改窗口 frame —— 窗口即悬浮框
    func applySettings() {
        guard let window = floatingWindow, let view = lyricsView else { return }
        let size = ConfigStore.shared.floatingSize
        window.frame = CGRect(origin: ConfigStore.shared.floatingOrigin, size: size)
        view.bounds = CGRect(origin: .zero, size: size)
        view.fontSize = ConfigStore.shared.floatingFontSize
        if !isLocked {
            view.backgroundColor = configuredBgColor()
        }
        // v1.0.150：尺寸变了必须重捕获频谱基准 —— 否则 spectrumTick 仍按旧基准逐帧写回
        // 「旧高度 + 0~24pt 脉冲」，表现为「改完高度自己又变回去了 / 自动变高」。
        refreshSpectrumBase()
    }

    // MARK: - 外观配置与强制重合成

    /// 配置的背景颜色 = 用户选的色 + 透明度滑杆
    private func configuredBgColor(alphaOverride: CGFloat? = nil) -> UIColor {
        let alpha = alphaOverride ?? CGFloat(ConfigStore.shared.floatingOpacity)
        return UIColor(hex: ConfigStore.shared.floatingBgColorHex, alpha: alpha)
    }

    /// 设置页选色后调用（选色是离散动作，直接强制重合成保证立即生效）
    func updateBgColor(hex: UInt32) {
        ConfigStore.shared.floatingBgColorHex = hex
        if !isLocked {
            lyricsView?.backgroundColor = configuredBgColor()
        }
        hardRefresh()
    }

    /// 实时更新悬浮歌词透明度
    func updateOpacity(_ value: Float) {
        ConfigStore.shared.floatingOpacity = value
        if !isLocked {
            lyricsView?.backgroundColor = configuredBgColor(alphaOverride: CGFloat(value))
        }
    }

    /// 🚨 强制 SpringBoard 全量重合成窗口内容
    ///
    /// 注册进 SB 的窗口 context 采用脏区差分：字号 / 透明度 / 尺寸这类「整面变化」
    /// 之后旧像素会残留在合成层里（重影），而截屏会触发全量重合成所以「一截屏就好了」。
    ///
    /// v1.0.115 关键修正：实测 SB 对托管窗口的 **isHidden 翻转不敏感**（可见性由 SB
    /// 侧接管，App 侧翻转疑似被忽略），而 **几何变化一定触发重合成**（折叠/展开动画
    /// 能实时跨应用显示就是证据）。这里改为「几何微扰」：frame 外扩 0.5pt 再复原，
    /// 同时保留 isHidden 快速翻转做双保险。
    func forceRecomposite() {
        guard let window = floatingWindow, !window.isHidden else { return }
        // v1.0.149：App 内为单通道渲染（SB 托管已摘除），无需几何微扰驱动 SB 重合成；
        // 旧实现的 isHidden 翻转会让窗口在 App 内闪 0.12s，故直接返回。
        if !hostingRegistered { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.commit()

        let original = window.frame
        // 几何微扰：外扩 0.5pt（强制 SB 把该窗口区域标记为脏）
        window.isHidden = true
        window.frame = original.insetBy(dx: -0.25, dy: -0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let window = self?.floatingWindow else { return }
            window.frame = original
            window.isHidden = false
            self?.lyricsView?.refreshHard()
        }
    }

    /// 🚨 v1.0.116：彻底重建窗口（设置变更后的「硬刷新」）
    ///
    /// 实测 SpringBoard 对托管 context 的内容更新极度惰性：只有触摸 / 截屏 /
    /// 大幅几何动画才触发重合成；0.5pt 微扰 + isHidden 翻转对尺寸 / 颜色这类
    /// 「内容变化」一律无效（v1.0.115 已证伪）。唯一确定生效的办法：销毁旧窗口、
    /// 重新创建并注册 —— 新 context 的首次合成必然是全量的。
    ///
    /// 代价：约 0.3~1s 的重建窗口期（注册带重试），设置变更（离散动作）可接受；
    /// 手势拖动 / 折叠 / 展开仍走轻量的 forceRecomposite（触摸驱动，本就有效）。
    private var hardRefreshWorkItem: DispatchWorkItem?

    /// v1.0.120：0.3s 防抖合并 —— 日志实测连续调硬刷新会引发「重建风暴」
    /// （2 分钟 25 次销毁重建），合并窗口内的多次调用为一次重建。
    func hardRefresh() {
        hardRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performHardRefresh() }
        hardRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 原 hardRefresh 主体：销毁重建系统级窗口
    private func performHardRefresh() {
        guard let oldWindow = floatingWindow else {
            // 窗口从未创建过（首次回前台等场景）：按开关状态直接创建
            if ConfigStore.shared.isFloatingLyricsOn { show() }
            return
        }
        let wasCollapsed = isCollapsed
        // 🚨 v1.0.152：写回配置的几何必须是「规范帧」（尺寸=配置尺寸），绝不能读
        // oldWindow.frame —— 它此刻的高度正带着频谱 0~24pt 的正弦拉伸（每帧被改）。
        // 旧写法每换一首歌（playerStateChanged → hardRefresh）就把「配置高度 + 最多 24pt」
        // 持久化一次，高度无上限累积 → 用户看到的「自动拉高、拉到超出屏幕」。
        let canonical = spectrumCanonicalFrame(of: oldWindow)
        let frame = wasCollapsed ? (savedExpandedFrame ?? canonical) : canonical

        // 折叠态重建后以展开态恢复（配置里存的本来就是展开尺寸/位置）
        if wasCollapsed {
            isCollapsed = false
            savedExpandedFrame = nil
            lyricsView?.setCollapsed(false)
        }
        ConfigStore.shared.floatingSize = frame.size
        ConfigStore.shared.floatingOrigin = frame.origin

        // 拆除旧窗口（unregister + 释放）
        teardownWindow()
        // v1.0.150：重建后的窗口尺寸取自配置 —— 旧频谱基准必须作废，否则高度会被旧基准写回
        refreshSpectrumBase()
        Logger.info("悬浮歌词：设置变更，重建系统级窗口")

        // 下一个 runloop 全量重建（show() 走完整创建 + 注册重试）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.show()
            if wasCollapsed {
                self.collapseWindow()
            }
        }
    }

    // MARK: - 内容刷新脉冲（v1.0.121）

    private var pulseWorkItem: DispatchWorkItem?

    /// v1.0.158：内容脉冲（几何动画）进行中 —— 期间频谱驱动必须让路。
    /// 🚨 两者都在写 `window.frame`：频谱每帧把 height 正弦拉伸 0~24pt，
    /// 脉冲又在其基础上 +24pt，叠加后即冲到 130pt / 144pt
    ///（用户日志：悬浮窗高度异常：130pt / 144pt 超出规范 97pt，已归位）。
    private var isPulsing = false

    /// v1.0.136：用户手势（拖动/捏合/折叠）进行中 —— 期间禁止脉冲动画。
    /// 🚨 脉冲的 frame 动画会把手势拖到的位置拉回去（=「有时拖不动」），
    /// 表现层与模型层分离即重影（桌面已被 v1.0.135 settlePulse 治好，
    /// 治不好的场景都是手势开始后脉冲才被调度出来的）。
    private var isUserInteracting = false

    /// 🚨 换句/换歌后的内容刷新：view 内部 transform 动画 SB 不感知（实测要点一下
    /// 才刷新），只有 window 级几何变化驱动 SB 跨应用重合成（折叠/展开动画实测实时可见）。
    /// 对窗口做一次底边下探 24pt 的往复动画（0.32s）驱动重合成。
    /// 🚨 v1.0.124/125 实测：2-3pt 微扰 SB 不标记脏区（换句后要点一下才变）；整体平移
    /// 20pt 虽有效但观感是「整个悬浮窗往上弹一下」（用户不可接受）→ 改锚定顶边只动底边。
    /// - Parameter force: true 时即使频谱驱动在跑也强制脉冲。用于「暂停」这一刻：
    ///   频谱驱动因 `isPlaying == false` 立即停摆，没有任何几何变化，图标刷新传不到 SB。
    func pulseRecomposite(force: Bool = false) {
        // v1.0.141：频谱驱动运行中时脉冲让路（几何已连续变化，脉冲会打架）
        guard force || spectrumLink == nil else { return }
        guard let window = floatingWindow, !isCollapsed, !suppressedInApp,
              !isUserInteracting else { return }
        pulseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performPulse(window: window) }
        pulseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// v1.0.135：手势开始前终止进行中的脉冲动画。
    /// 🚨 拖动重影根因：performPulse 捕获动画开始时的 frame，其 completion 会把窗口
    /// 拉回旧 origin —— 若用户在脉冲动画期间开始拖动，CA 表现层仍在旧位置播放
    /// 动画、模型层已被拖到新位置 = 同一窗口两处影像（重影）。手势开始即取消动画并落定。
    private func settlePulse() {
        pulseWorkItem?.cancel()
        // v1.0.158：手势打断脉冲 → 必须先解除闸门，否则频谱被永久挡在门外
        isPulsing = false
        guard let window = floatingWindow else { return }
        window.pulseContentLock = false
        // 终止进行中的 frame 动画（表现层立即吸附到模型值 = 当前拖动位置）
        UIView.performWithoutAnimation {
            window.layer.removeAllAnimations()
            window.rootViewController?.view?.layer.removeAllAnimations()
            let target = window.frame
            window.frame = target
            window.rootViewController?.view.frame =
                CGRect(origin: .zero, size: target.size)
        }
    }

    private func performPulse(window: FloatingSystemWindow) {
        guard window === floatingWindow, !isCollapsed, !isUserInteracting,
              !isPulsing, !isParkedOffScreen else { return }
        // 🚨 v1.0.158：基准取「规范帧」（尺寸 = 配置值），绝不读 window.frame ——
        // 频谱驱动此刻正把 frame.height 正弦拉伸 0~24pt，抓到的 original 往往就是
        //「已拉伸值」，再 +24pt 即 130 / 144pt（用户日志里那条高度异常）。
        let original = spectrumCanonicalFrame(of: window)
        isPulsing = true
        // v1.0.128：内容锁定脉冲 v2 —— UIWindow 拉伸根视图不走 layoutSubviews
        //（时序上拉伸动画先跑、纠正后到 = v1.0.127 仍可见「下拉再恢复」的根因），
        // 改为在同一个动画事务内反向钉住根视图：窗口扩 24pt 的同时把 root 帧钉回
        // 原尺寸，同事务最终模型=锁定值，不存在可见的中间态。
        let root = window.rootViewController?.view
        let pinned = CGRect(origin: .zero, size: original.size)
        window.pulseContentLock = true
        window.pulseContentSize = original.size
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseInOut]) {
            window.frame = CGRect(origin: original.origin,
                                  size: CGSize(width: original.width,
                                               height: original.height + 24))
            root?.frame = pinned
        } completion: { _ in
            guard window === self.floatingWindow else {
                window.pulseContentLock = false
                root?.frame = pinned
                self.isPulsing = false
                return
            }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut], animations: {
                window.frame = original
                root?.frame = pinned
            }, completion: { _ in
                window.pulseContentLock = false
                root?.frame = pinned
                self.isPulsing = false
                // 锁定核查：只在异常时留痕（防正常脉冲淹没取证日志）
                if let r = root, abs(r.frame.size.height - original.height) > 0.5 {
                    Logger.persist("脉冲锁定异常 root=\(Int(r.frame.size.height)) 期望=\(Int(original.height)) winH=\(Int(window.frame.size.height))")
                }
            })
        }
    }

    // MARK: - v1.0.141 音乐频谱（悬浮窗可视化）

    @objc private func artworkLoaded() {
        // v1.0.144：封面通知可能来自后台线程，UIKit 一律回主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lyricsView?.setArtwork(PlayerManager.shared.currentArtwork)
            if self.lyricsView?.isCollapsedState == true {
                Logger.info("悬浮窗封面已回填")
            }
        }
    }

    private var spectrumLink: CADisplayLink?
    private var spectrumBaseFrame: CGRect?
    private var spectrumPhase: Double = 0

    /// 频谱开关/播放状态变化后调用：启动或停止显示链接
    func refreshSpectrumState() {
        let on = ConfigStore.shared.floatingSpectrumOn
        if on, spectrumLink == nil {
            lyricsView?.setSpectrumVisible(true)
            let link = CADisplayLink(target: self, selector: #selector(spectrumTick))
            link.preferredFramesPerSecond = 20
            link.add(to: .main, forMode: .common)
            spectrumLink = link
            spectrumBaseFrame = nil
            Logger.persist("频谱驱动已启动")
        } else if !on, let link = spectrumLink {
            link.invalidate()
            spectrumLink = nil
            restoreSpectrumGeometry()
            lyricsView?.setSpectrumVisible(false)
        }
    }

    /// 手势/重建改了窗口几何后重新捕获频谱基准帧
    func refreshSpectrumBase() {
        spectrumBaseFrame = nil
    }

    /// 🚨 v1.0.152：频谱的「规范基准帧」—— 位置取窗口当前位置，**尺寸一律取配置值**。
    ///
    /// 绝不能拿 `window.frame` 当基准：它的 height 每一帧都被自己 +0~24pt 的正弦拉伸
    /// （用来驱动 SB 重合成），拿它当基准等于每帧把「上一帧已拉伸过的高度」再当新基准，
    /// 高度按 +0~24pt/帧 累积 —— 几秒内就能顶穿屏幕（用户实测的「无限自动拉高」）。
    /// 脉冲动画（performPulse 底边 +24pt）同理不得进入基准或配置。
    private func spectrumCanonicalFrame(of window: UIWindow) -> CGRect {
        return CGRect(origin: window.frame.origin, size: ConfigStore.shared.floatingSize)
    }

    @objc private func spectrumTick() {
        guard let window = floatingWindow, !isCollapsed, !isUserInteracting, !suppressedInApp,
              !isParkedOffScreen, !isPulsing,
              PlayerManager.shared.isPlaying else {
            if spectrumBaseFrame != nil { restoreSpectrumGeometry() }
            return
        }
        // 频谱条数据（EQ tap 的并行带通分析）
        lyricsView?.spectrumView.levels = AudioEqualizer.shared.currentLevels()
        // 几何驱动：底边 0~24pt 正弦往复（内容锁钉住根视图 → 视觉零变化），
        // 连续 window 级几何变化强制 SB 逐帧重合成 → 频谱跨应用实时可见
        // 🚨 v1.0.152：基准一律取「规范帧」（尺寸=配置值），绝不拿 window.frame 当基准
        // —— 它此刻的 height 正带着本帧要叠加的振荡，用作基准会逐帧累积放大（无限拉高）。
        let canonical = spectrumCanonicalFrame(of: window)
        // 超高自愈：超出规范高度 26pt（> 正弦最大振幅 24pt）= 基准/配置被污染过，立即归位。
        // 这也是存量脏数据的兜底收敛点（历史版本已被拉高的窗口跑一帧即恢复）。
        if window.frame.height > canonical.height + 26 {
            Logger.persist("悬浮窗高度异常：\(Int(window.frame.height))pt 超出规范 \(Int(canonical.height))pt，已归位")
            spectrumBaseFrame = canonical
        }
        if spectrumBaseFrame == nil {
            spectrumBaseFrame = canonical
        }
        var base = spectrumBaseFrame!
        // 位置 / 尺寸任一偏离规范值 → 重新捕获（拖动窗口、设置页改尺寸、脉冲残影都能自愈）
        if abs(window.frame.origin.x - base.origin.x) > 1
            || abs(window.frame.origin.y - base.origin.y) > 1
            || abs(canonical.width - base.width) > 1
            || abs(canonical.height - base.height) > 1 {
            spectrumBaseFrame = canonical
            base = canonical
        }
        spectrumPhase += 0.35
        if spectrumPhase > .pi * 2 { spectrumPhase -= .pi * 2 }
        let osc = (0.5 - 0.5 * cos(spectrumPhase)) * 24
        window.pulseContentLock = true
        window.pulseContentSize = base.size
        window.frame = CGRect(origin: base.origin,
                              size: CGSize(width: base.width, height: base.height + osc))
    }

    private func restoreSpectrumGeometry() {
        // v1.0.156：移出可见区期间禁止归位 —— 否则守卫分支每帧把窗口拉回屏幕内，
        // 亮屏后的 2.5s「避杀窗口」就白做了（锁屏上也看不到）
        guard !isParkedOffScreen else { spectrumBaseFrame = nil; return }
        guard let window = floatingWindow else { spectrumBaseFrame = nil; return }
        window.pulseContentLock = false
        if let base = spectrumBaseFrame {
            UIView.performWithoutAnimation { window.frame = base }
            window.rootViewController?.view.setNeedsLayout()
        }
        spectrumBaseFrame = nil
    }

    // MARK: - 手势（窗口即悬浮框：拖动 = 移动窗口，捏合 = 缩放窗口）

    private func setupGestures() {
        guard let view = lyricsView else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // v1.0.110：上/下滑折叠成小圆点；折叠态点按展开（让位于双击锁定）
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeCollapse(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCollapsedTap))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        // v1.0.154：所有窗口手势都先过 delegate —— 落在控制条上的触摸不参与
        // 拖动 / 捏合 / 折叠 / 双击锁定（否则点按钮会被手势抢走 → 按钮基本按不动）
        for recognizer in view.gestureRecognizers ?? [] {
            recognizer.delegate = self
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let window = floatingWindow else { return }
        // v1.0.135：拖动开始先终止脉冲动画（动画 completion 会把窗口拉回拖动前
        // 的位置，且表现/模型层分离造成重影）
        if gesture.state == .began {
            settlePulse()
            // v1.0.149：① App 内拖动先摘掉 SB 托管（双通道重影根因）；
            // ② 清频谱基准 —— 否则 spectrumTick 守卫失败分支会把窗口拉回拖动前的位置
            //    （表现为「刚开始拖动窗口跳一下 / 拖不动」）。
            refreshSpectrumBase()
            // v1.0.151：App 内窗口理论上就是未注册的（预览一律用全新未注册窗口）。
            // 真出现注册态只留取证 —— 不在这里摘托管：就地摘除再补注册会踩「同窗重注册
            // 被 SB 摘路由」，而销毁重建会打断刚开始的手势。
            if UIApplication.shared.applicationState == .active, hostingRegistered {
                Logger.persist("异常：App 内窗口处于 SB 注册态（可能存在双通道重影）")
            }
            isUserInteracting = true
        }
        let translation = gesture.translation(in: nil)
        window.frame.origin.x += translation.x
        window.frame.origin.y += translation.y
        gesture.setTranslation(.zero, in: nil)

        if gesture.state == .ended || gesture.state == .cancelled {
            clampWindowIntoScreen(window)
            isUserInteracting = false
            refreshSpectrumBase()
            // v1.0.136：竖直快速轻扫 = 折叠成圆点。pan 一直在 swipe 之前 begin，
            // 原 UISwipeGestureRecognizer 永远收不到事件（折叠手势操作不出来的根因）。
            // 阈值 1000pt/s + 纵向占优：正常的慢速拖动窗口不受影响。
            let v = gesture.velocity(in: nil)
            if !isCollapsed, abs(v.y) > 1000, abs(v.y) > abs(v.x) * 1.5 {
                collapseWindow()
                return
            }
            // v1.0.138：拖动清理升级 —— 0.5pt 微扰 SB 已证伪不标脏区（v1.0.124/125）。
            // 后台改用 24pt 底边脉冲（实测可驱动跨应用重合成）；App 内预览态 App 本地
            // 渲染与 SB 托管合成双通道并存，唯有整窗重建能确定清残留。
            if UIApplication.shared.applicationState == .active {
                // v1.0.149：App 内已是单通道渲染（SB 托管已摘除）→ 无残影，不必整窗重建；
                // 仍在注册态（回退开关 / 异常路径）时保留重建兜底。
                if hostingRegistered {
                    Logger.info("拖动结束清理：App内重建窗口清残影")
                    hardRefresh()
                } else {
                    Logger.info("拖动结束清理：App内单通道渲染，免重建")
                }
            } else {
                pulseRecomposite()
            }
            if isCollapsed {
                savedExpandedFrame?.origin = window.frame.origin
            } else {
                ConfigStore.shared.floatingOrigin = window.frame.origin
            }
        }
    }

    /// 捏合缩放：按双指的横向 / 纵向位移分量分别缩放宽高
    /// —— 竖直拉只改高度，横向拉只改宽度，斜着拉等比缩放
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isLocked, !isCollapsed, let window = floatingWindow else { return }
        let screenW = UIScreen.main.bounds.width

        switch gesture.state {
        case .began:
            settlePulse()
            // v1.0.152：清频谱基准 —— 否则 spectrumTick 的守卫分支每帧 restoreSpectrumGeometry()
            // 会把窗口尺寸拉回捏合前，捏合缩放被持续顶回去（基准里还可能残留振荡高度）。
            refreshSpectrumBase()
            isUserInteracting = true
            pinchStartFrame = window.frame
            pinchStartFont = ConfigStore.shared.floatingFontSize
            pinchStartSpan = pinchSpan(gesture)

        case .changed:
            guard let start = pinchStartFrame else { break }
            var width = start.width
            var height = start.height

            if let span = pinchStartSpan, let now = pinchSpan(gesture),
               span.x > 8 || span.y > 8 {
                // 分量缩放：只按手指确实移动的那个方向改变对应边
                if span.x > 8 {
                    width = clamp(start.width * (now.x / span.x), min: 140, max: screenW - 16)
                }
                if span.y > 8 {
                    height = clamp(start.height * (now.y / span.y), min: 72, max: 360)
                }
            } else {
                // 退化（单指/间距过小）：等比缩放
                width = clamp(start.width * gesture.scale, min: 140, max: screenW - 16)
                height = clamp(start.height * gesture.scale, min: 72, max: 360)
            }

            window.frame = CGRect(origin: start.origin,
                                  size: CGSize(width: width, height: height))
            let ratio = height / max(1, start.height)
            lyricsView?.fontSize = clamp(pinchStartFont * ratio, min: 10, max: 34)

        case .ended, .cancelled:
            clampWindowIntoScreen(window)
            ConfigStore.shared.floatingSize = window.bounds.size
            ConfigStore.shared.floatingOrigin = window.frame.origin
            ConfigStore.shared.floatingFontSize = lyricsView?.fontSize ?? ConfigStore.shared.floatingFontSize
            pinchStartFrame = nil
            pinchStartSpan = nil
            refreshSpectrumBase()
            // v1.0.138：与拖动同理，捏合结束清理升级（见 handlePan）
            // v1.0.149：App 内已单通道渲染 → 无残影，免整窗重建
            if UIApplication.shared.applicationState == .active {
                if hostingRegistered { hardRefresh() }
            } else {
                pulseRecomposite()
            }

        default:
            pinchStartFrame = nil
            pinchStartSpan = nil
            isUserInteracting = false
        }
    }

    /// 当前双指的横向 / 纵向间距
    private func pinchSpan(_ gesture: UIPinchGestureRecognizer) -> (x: CGFloat, y: CGFloat)? {
        guard gesture.numberOfTouches >= 2 else { return nil }
        let p0 = gesture.location(ofTouch: 0, in: nil)
        let p1 = gesture.location(ofTouch: 1, in: nil)
        return (abs(p0.x - p1.x), abs(p0.y - p1.y))
    }

    @objc private func handleDoubleTap() {
        isLocked.toggle()
        guard let view = lyricsView else { return }
        UIView.animate(withDuration: 0.2) {
            view.backgroundColor = self.configuredBgColor(alphaOverride: self.isLocked ? 0.25 : nil)
        }
    }

    // MARK: - 折叠 / 展开（同播放条：滑动收起，点按展开）

    @objc private func handleSwipeCollapse(_ gesture: UISwipeGestureRecognizer) {
        guard !isCollapsed, !isLocked else { return }
        collapseWindow()
    }

    @objc private func handleCollapsedTap() {
        guard isCollapsed else { return }
        expandWindow()
    }

    /// 折叠：窗口缩成 48×48 圆点（同播放条滑动收起的交互）
    private func collapseWindow() {
        guard let window = floatingWindow, !isCollapsed else { return }
        settlePulse()
        isCollapsed = true
        // v1.0.152：保存的是规范帧（不含频谱振荡），否则展开时会带着振荡高度回来
        savedExpandedFrame = spectrumCanonicalFrame(of: window)
        let side: CGFloat = 48
        let screen = UIScreen.main.bounds
        let origin = CGPoint(x: clamp(window.frame.origin.x, min: 6, max: max(6, screen.width - side - 6)),
                             y: clamp(window.frame.origin.y, min: 6, max: max(6, screen.height - side - 6)))
        lyricsView?.setCollapsed(true)
        Logger.info("悬浮歌词：已折叠成圆点，点按可展开")
        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.75, initialSpringVelocity: 0.8,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            window.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        } completion: { [weak self] _ in
            self?.forceRecomposite()
        }
    }

    /// 展开：恢复折叠前的尺寸与位置
    private func expandWindow() {
        guard let window = floatingWindow, isCollapsed else { return }
        isCollapsed = false
        let target = savedExpandedFrame ?? CGRect(origin: window.frame.origin,
                                                  size: ConfigStore.shared.floatingSize)
        lyricsView?.setCollapsed(false)
        Logger.info("悬浮歌词：已展开恢复")
        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.75, initialSpringVelocity: 0.8,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            window.frame = target
        } completion: { [weak self] _ in
            self?.forceRecomposite()
        }
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    /// 保证悬浮窗完整留在屏幕内
    private func clampWindowIntoScreen(_ window: UIWindow) {
        // v1.0.156：移出可见区期间不得钳回屏幕内
        guard !isParkedOffScreen else { return }
        let screen = UIScreen.main.bounds
        let maxX = Swift.max(6, screen.width - window.frame.width - 6)
        let maxY = Swift.max(6, screen.height - window.frame.height - 6)
        window.frame.origin = CGPoint(x: clamp(window.frame.origin.x, min: 6, max: maxX),
                                      y: clamp(window.frame.origin.y, min: 6, max: maxY))
    }

    // MARK: - v1.0.154 悬浮窗播放控制条（上一首 / 播放暂停 / 下一首）

    /// 控制条按钮 → 播放器。播放器状态回传由 playerStateChanged 通知统一驱动
    /// （换歌 / 暂停 / 恢复都会刷新图标）。
    private func setupControlActions() {
        guard let bar = lyricsView?.controlBar else { return }
        bar.onPrevious = { [weak self] in self?.controlPrevious() }
        bar.onToggle = { [weak self] in self?.controlToggle() }
        bar.onNext = { [weak self] in self?.controlNext() }
    }

    /// 把「播放器是否在播」同步到控制条中间按钮的图标
    private func refreshControlState() {
        guard let bar = lyricsView?.controlBar else { return }
        let playing = PlayerManager.shared.isPlaying
        guard bar.isPlaying != playing else { return }
        bar.isPlaying = playing
        // 图标属于「内容变化」——SpringBoard 对托管 context 只认几何变化，必须再推一次脉冲。
        // 先清频谱基准：暂停后 spectrumTick 立刻走守卫分支，每帧 restoreSpectrumGeometry()
        // 会把窗口钉回基准，与脉冲的几何动画打架（表现为图标不刷新）。
        refreshSpectrumBase()
        pulseRecomposite(force: true)
    }

    private func controlPrevious() {
        Logger.info("悬浮窗控制条：上一首")
        PlayerManager.shared.previous()
        refreshControlState()
    }

    private func controlToggle() {
        Logger.info("悬浮窗控制条：播放暂停切换")
        PlayerManager.shared.togglePlayPause()
        refreshControlState()
    }

    private func controlNext() {
        Logger.info("悬浮窗控制条：下一首")
        PlayerManager.shared.next()
        refreshControlState()
    }

    // MARK: - 通知

    private func observeNotifications() {
        let center = NotificationCenter.default
        // 幂等：hardRefresh 重建窗口会重复走 show() → observeNotifications，
        // 不先移除会导致通知重复投递
        center.removeObserver(self, name: .lyricsLineChanged, object: nil)
        center.removeObserver(self, name: .playerStateChanged, object: nil)
        center.removeObserver(self, name: .lyricsLoaded, object: nil)
        center.removeObserver(self, name: .artworkLoaded, object: nil)
        center.addObserver(self, selector: #selector(lyricsLineChanged(_:)),
                           name: .lyricsLineChanged, object: nil)
        center.addObserver(self, selector: #selector(playerStateChanged),
                           name: .playerStateChanged, object: nil)
        center.addObserver(self, selector: #selector(lyricsLoadedChanged),
                           name: .lyricsLoaded, object: nil)
        // v1.0.141：封面更新 → 折叠圆点换封面
        center.addObserver(self, selector: #selector(artworkLoaded),
                           name: .artworkLoaded, object: nil)
    }

    /// 当前歌曲标识，用于判断换歌
    private var lastSongKey: String?

    /// 换歌时重置行号并显示歌名，避免停留上一首的最后一句
    @objc private func playerStateChanged() {
        DispatchQueue.main.async {
            // v1.0.154：控制条图标跟随播放状态（暂停 / 恢复 / 换歌都会走到这里）
            self.refreshControlState()
            guard let song = PlayerManager.shared.currentSong else { return }
            let key = "\(song.name)-\(song.singer)"
            guard key != self.lastSongKey else { return }
            self.lastSongKey = key
            self.lyricsIndex = -1
            Logger.info("悬浮歌词：检测到换歌，硬刷新窗口")
            self.refreshPlaceholder()
            // v1.0.124：换歌走硬刷新（低频事件，销毁重建保证 SB 全量重合成；
            // 仅靠小脉冲实测不够 —— 换歌后悬浮窗停在旧内容要点一下才变）
            self.hardRefresh()
        }
    }

    /// v1.0.124：歌词状态落定（换歌清空 / 新词解析完成 / 无歌词）→ 刷新悬浮窗内容
    @objc private func lyricsLoadedChanged() {
        DispatchQueue.main.async {
            self.refreshPlaceholder()
        }
    }

    // MARK: - 歌词

    private func refreshPlaceholder() {
        defer { pulseRecomposite() }
        guard let song = PlayerManager.shared.currentSong else {
            lyricsView?.setLines(["", "墨守music", ""], animated: false)
            return
        }
        let lyrics = PlayerManager.shared.currentLyrics
        if lyrics.isEmpty {
            lyricsView?.setPlaceholder(name: song.name, singer: song.singer)
            return
        }
        // v1.0.122：窗口重建后立即恢复当前句 —— 此前歌词非空时什么都不渲染，
        // 新窗口空白，要等下一句通知才有内容；若后台歌词驱动停摆就永远停在占位。
        let idx = PlayerManager.shared.currentLyricIndex
        let safe = idx >= 0 && idx < lyrics.count ? idx : 0
        lyricsIndex = safe
        let prevLine = safe > 0 ? lyrics[safe - 1].text : ""
        let nextLine = safe + 1 < lyrics.count ? lyrics[safe + 1].text : ""
        lyricsView?.setLines([prevLine, lyrics[safe].text, nextLine], animated: false)
    }

    @objc private func lyricsLineChanged(_ notification: Notification) {
        guard let line = notification.object as? LRCLine else { return }
        DispatchQueue.main.async {
            let index = notification.userInfo?["index"] as? Int ?? -1
            let lines = PlayerManager.shared.currentLyrics
            // 只有顺序切到下一句才播放上翻动效；跳播/换歌直接刷新
            let animated = index >= 0 && self.lyricsIndex >= 0 && index == self.lyricsIndex + 1
            self.lyricsIndex = index

            if lines.isEmpty {
                self.refreshPlaceholder()
                return
            }

            let safeIndex = index >= 0 && index < lines.count ? index : 0
            let prev = safeIndex > 0 ? lines[safeIndex - 1].text : ""
            let current = line.text
            let next = safeIndex + 1 < lines.count ? lines[safeIndex + 1].text : ""
            self.lyricsView?.setLines([prev, current, next], animated: animated)
            // v1.0.122 诊断：确认跨应用场景下翻句通知是否送达（每句一条，环形缓冲可承受）
            Logger.info("悬浮歌词跨应用翻句: idx=\(index)/\(lines.count) 动效=\(animated)")
            self.pulseRecomposite()
        }
    }
}

/// 悬浮窗根视图 —— 文档第七节：空白区点击穿透（触摸落到下层应用 / App 主窗口）
final class FloatingRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}


// MARK: - v1.0.154 控制条触摸隔离

extension FloatingLyricsManager: UIGestureRecognizerDelegate {

    /// 控制条（上一首 / 播放暂停 / 下一首）区域内的触摸不喂给窗口手势 ——
    /// 否则点按钮会连带触发拖动（窗口跟着手指跑）或折叠手势，表现为「按钮按不动 / 窗口乱跳」。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let bar = lyricsView?.controlBar, !bar.isHidden else { return true }
        return !bar.bounds.contains(touch.location(in: bar))
    }
}
