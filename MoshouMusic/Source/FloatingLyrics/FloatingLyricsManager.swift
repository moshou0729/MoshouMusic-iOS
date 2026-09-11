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

    /// v1.0.134：熄屏自保（强制）—— 亮屏瞬间彻底拆除系统级窗口避开系统清杀。
    /// 根因由 v1.0.132 开关实验坐实：开关打开后熄屏点亮不再停播。
    /// 拆除 8s 后在后台自动重建（被杀检查时刻有漂移：历史 1.4~4s，v1.0.139 实测
    /// 一例正好 ≈5s 并撞上 5s 重建时刻 —— 重建即暴露窗口即被杀。8s 为 v1.0.134
    /// 时代多日实测零被杀的延迟）。
    func screenWakeSelfGuardTeardown() {
        settingsPreviewActive = false
        hardRefreshWorkItem?.cancel()
        pulseWorkItem?.cancel()
        selfGuardReshowWork?.cancel()
        teardownWindow()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.suppressedInApp, ConfigStore.shared.isFloatingLyricsOn else { return }
            // v1.0.148：两重收紧 —— v1.0.146/147 两次现场都是「重建日志之后心跳全断」：
            //  ① 延迟 8s → 20s：避开亮屏后 mediaserverd 的音频仲裁窗口；
            //  ② 音频管线不健康时直接放弃这次重建，绝不在「已停播」状态下去注册窗口。
            guard PlayerManager.shared.isPlaybackHealthy else {
                Logger.persist("熄屏自保：音频管线未在播，跳过本次后台重建（规避注册窗口风险）")
                return
            }
            self.show()
            Logger.persist("熄屏自保：已延迟重建悬浮窗（亮屏后 20s）")
            // 重建后 6s 存活确认 —— 下次日志能直接区分「重建即死」与「别的原因」
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                Logger.persist("熄屏自保：重建后 6s 存活确认（音频健康=\(PlayerManager.shared.isPlaybackHealthy)）")
            }
        }
        selfGuardReshowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: work)
        Logger.persist("熄屏自保：亮屏时已拆除悬浮窗，20s 后自动重建")
    }

    /// 离开 App（切其他应用 / 回桌面 / 锁屏）：恢复悬浮窗
    func resumeWhenLeavingApp() {
        if suppressedInApp, ConfigStore.shared.isFloatingLyricsOn {
            suppressedInApp = false
            Logger.info("离开 App：恢复悬浮歌词窗口")
            show()
            return
        }
        // v1.0.149：App 内预览期间窗口未注册 SB 托管 → 离开 App 必须补注册，
        // 否则切到桌面 / 其他应用后悬浮窗不可见（跨应用显示全靠这份注册）。
        // 只在 App 真正退出活跃态时补 —— 下拉通知中心 / 控制中心只是瞬时失焦，
        // 避免频繁 unregister/register 抖动（反复重注册会让 SB 移除窗口）。
        if floatingWindow != nil, !hostingRegistered, ConfigStore.shared.isFloatingLyricsOn,
           UIApplication.shared.applicationState != .active {
            Logger.info("离开 App：补注册 SB 托管（此前为 App 内预览模式）")
            registerHostingWithRetry()
        }
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
        if let window = floatingWindow {
            window.isHidden = false
            applySettings()
            registerHostingWithRetry()
            refreshPlaceholder()
            refreshSpectrumState()
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

        // 让窗口可见但不长期抢占 key（否则会影响输入框等）
        let previousKey = currentKeyWindow()
        window.isHidden = false
        window.makeKeyAndVisible()
        previousKey?.makeKey()

        observeNotifications()
        refreshPlaceholder()

        // contextId 要等下一个 runloop 才生成，注册带重试
        registerHostingWithRetry()
        refreshSpectrumState()
    }

    func hide() {
        if let window = floatingWindow, hostingRegistered {
            FloatingWindowHosting.unregister(window: window)
            hostingRegistered = false
            isGlobalWindowReady = false
            lastContextId = 0
        }
        floatingWindow?.isHidden = true
        registerAttempts = 0
        // v1.0.150：顺带清一次孤儿（见 purgeOrphanFloatingWindows）
        purgeOrphanFloatingWindows()
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
        guard let window = floatingWindow, hostingRegistered else { return }
        FloatingWindowHosting.unregister(window: window)
        hostingRegistered = false
        isGlobalWindowReady = false
        Logger.info("悬浮歌词：已摘除 SB 托管（App 内单通道渲染，消除拖动重影）")
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
        let frame = wasCollapsed ? (savedExpandedFrame ?? oldWindow.frame) : oldWindow.frame

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
    func pulseRecomposite() {
        // v1.0.141：频谱驱动运行中时脉冲让路（几何已连续变化，脉冲会打架）
        guard spectrumLink == nil else { return }
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
        guard window === floatingWindow, !isCollapsed, !isUserInteracting else { return }
        let original = window.frame
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
                return
            }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut], animations: {
                window.frame = original
                root?.frame = pinned
            }, completion: { _ in
                window.pulseContentLock = false
                root?.frame = pinned
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

    @objc private func spectrumTick() {
        guard let window = floatingWindow, !isCollapsed, !isUserInteracting, !suppressedInApp,
              PlayerManager.shared.isPlaying else {
            if spectrumBaseFrame != nil { restoreSpectrumGeometry() }
            return
        }
        // 频谱条数据（EQ tap 的并行带通分析）
        lyricsView?.spectrumView.levels = AudioEqualizer.shared.currentLevels()
        // 几何驱动：底边 0~24pt 正弦往复（内容锁钉住根视图 → 视觉零变化），
        // 连续 window 级几何变化强制 SB 逐帧重合成 → 频谱跨应用实时可见
        if spectrumBaseFrame == nil {
            spectrumBaseFrame = window.frame
        }
        var base = spectrumBaseFrame!
        // 手势期间拖动了窗口 → 重新捕获基准
        if abs(window.frame.origin.x - base.origin.x) > 1
            || abs(window.frame.origin.y - base.origin.y) > 1
            || abs(window.frame.width - base.width) > 1
            // v1.0.150：高度不能直接拿 window.frame 比（本帧要被自己 +osc），
            // 改比「配置高度 vs 基准高度」—— 设置页改高度后能自愈重捕获基准。
            || abs(ConfigStore.shared.floatingSize.height - base.height) > 1 {
            spectrumBaseFrame = window.frame
            base = window.frame
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
            if UIApplication.shared.applicationState == .active {
                dropHostingForInApp()
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
        savedExpandedFrame = window.frame
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
        let screen = UIScreen.main.bounds
        let maxX = Swift.max(6, screen.width - window.frame.width - 6)
        let maxY = Swift.max(6, screen.height - window.frame.height - 6)
        window.frame.origin = CGPoint(x: clamp(window.frame.origin.x, min: 6, max: maxX),
                                      y: clamp(window.frame.origin.y, min: 6, max: maxY))
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
