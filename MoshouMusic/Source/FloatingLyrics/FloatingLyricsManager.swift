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

    func show() {
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
        lyricView.backgroundColor = UIColor.black
            .withAlphaComponent(CGFloat(ConfigStore.shared.floatingOpacity))
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
            view.backgroundColor = UIColor.black
                .withAlphaComponent(CGFloat(ConfigStore.shared.floatingOpacity))
        }
    }

    /// 实时更新悬浮歌词透明度
    func updateOpacity(_ value: Float) {
        ConfigStore.shared.floatingOpacity = value
        if !isLocked {
            lyricsView?.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(value))
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
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let window = floatingWindow else { return }
        let translation = gesture.translation(in: nil)
        window.frame.origin.x += translation.x
        window.frame.origin.y += translation.y
        gesture.setTranslation(.zero, in: nil)

        if gesture.state == .ended {
            clampWindowIntoScreen(window)
            ConfigStore.shared.floatingOrigin = window.frame.origin
        }
    }

    /// 捏合缩放：按双指的横向 / 纵向位移分量分别缩放宽高
    /// —— 竖直拉只改高度，横向拉只改宽度，斜着拉等比缩放
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isLocked, let window = floatingWindow else { return }
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
            view.backgroundColor = UIColor.black.withAlphaComponent(
                self.isLocked ? 0.25 : CGFloat(ConfigStore.shared.floatingOpacity))
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
        center.addObserver(self, selector: #selector(lyricsLineChanged(_:)),
                           name: .lyricsLineChanged, object: nil)
        center.addObserver(self, selector: #selector(playerStateChanged),
                           name: .playerStateChanged, object: nil)
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
            self.refreshPlaceholder()
        }
    }

    // MARK: - 歌词

    private func refreshPlaceholder() {
        guard let song = PlayerManager.shared.currentSong else {
            lyricsView?.setLines(["", "墨守music", ""], animated: false)
            return
        }
        if PlayerManager.shared.currentLyrics.isEmpty {
            lyricsView?.setPlaceholder(name: song.name, singer: song.singer)
        }
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
