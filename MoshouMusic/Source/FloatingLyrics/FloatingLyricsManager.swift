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
        guard !settingsPreviewActive else { return }
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

    /// 离开 App（切其他应用 / 回桌面 / 锁屏）：恢复悬浮窗
    func resumeWhenLeavingApp() {
        guard suppressedInApp, ConfigStore.shared.isFloatingLyricsOn else { return }
        suppressedInApp = false
        Logger.info("离开 App：恢复悬浮歌词窗口")
        show()
    }

    /// 拆除系统级窗口（unregister + 释放，不重建）
    private func teardownWindow() {
        if let window = floatingWindow, hostingRegistered {
            FloatingWindowHosting.unregister(window: window)
            hostingRegistered = false
            isGlobalWindowReady = false
            lastContextId = 0
            window.isHidden = true
        }
        floatingWindow = nil
        lyricsView = nil
        registerAttempts = 0
    }

    func show() {
        guard !suppressedInApp else { return }
        if let window = floatingWindow {
            window.isHidden = false
            applySettings()
            registerHostingWithRetry()
            refreshPlaceholder()
            return
        }

        // —— 文档 3.4：窗口就是悬浮框大小 ——
        let frame = CGRect(origin: ConfigStore.shared.floatingOrigin,
                           size: ConfigStore.shared.floatingSize)
        let window = FloatingSystemWindow(frame: frame)
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        window.backgroundColor = .clear
        window.isOpaque = false
        if let scene = activeScene() {
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

    private func registerHostingWithRetry(attempt: Int = 0) {
        guard let window = floatingWindow, !hostingRegistered else { return }
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

    /// 🚨 换句/换歌后的内容刷新：view 内部 transform 动画 SB 不感知（实测要点一下
    /// 才刷新），只有 window 级几何变化驱动 SB 跨应用重合成（折叠/展开动画实测实时可见）。
    /// 对窗口做一次底边下探 24pt 的往复动画（0.32s）驱动重合成。
    /// 🚨 v1.0.124/125 实测：2-3pt 微扰 SB 不标记脏区（换句后要点一下才变）；整体平移
    /// 20pt 虽有效但观感是「整个悬浮窗往上弹一下」（用户不可接受）→ 改锚定顶边只动底边。
    func pulseRecomposite() {
        guard let window = floatingWindow, !isCollapsed, !suppressedInApp else { return }
        pulseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performPulse(window: window) }
        pulseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func performPulse(window: FloatingSystemWindow) {
        guard window === floatingWindow, !isCollapsed else { return }
        let original = window.frame
        // v1.0.125：底边下探 —— 顶边固定，高度向下扩 24pt 再收回。歌词文字几乎不动
        //（按比例仅微移数 pt），只有底边轻轻「呼吸」，观感远好于整体上跳。
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseInOut]) {
            window.frame = CGRect(origin: original.origin,
                                  size: CGSize(width: original.width,
                                               height: original.height + 24))
        } completion: { _ in
            guard window === self.floatingWindow else { return }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) {
                window.frame = original
            }
        }
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
        let translation = gesture.translation(in: nil)
        window.frame.origin.x += translation.x
        window.frame.origin.y += translation.y
        gesture.setTranslation(.zero, in: nil)

        if gesture.state == .ended {
            clampWindowIntoScreen(window)
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
            forceRecomposite()

        default:
            pinchStartFrame = nil
            pinchStartSpan = nil
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
        center.addObserver(self, selector: #selector(lyricsLineChanged(_:)),
                           name: .lyricsLineChanged, object: nil)
        center.addObserver(self, selector: #selector(playerStateChanged),
                           name: .playerStateChanged, object: nil)
        center.addObserver(self, selector: #selector(lyricsLoadedChanged),
                           name: .lyricsLoaded, object: nil)
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
