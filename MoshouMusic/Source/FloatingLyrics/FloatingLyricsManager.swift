import UIKit

/// 系统级悬浮歌词窗口 — TrollStore 专属能力
///
/// 三层保障，确保切到别的应用后依然悬浮：
/// 1. FloatingSystemWindow 覆写 UIWindow 私有方法（_isSystemWindow / _isSecure 等），
///    让 backboardd 按「系统窗口」渲染，应用退后台也不隐藏；
/// 2. 通过 SBSAccessibilityWindowHostingController 把窗口注册到 SpringBoard 的
///    辅助功能窗口托管服务 —— 这才是跨应用（主屏 / 其他 App / 锁屏）显示的关键；
/// 3. 退后台后多次「保活」重试：重新声明窗口层级并补注册。
///
/// ⚠️ 触摸处理：系统安全窗口参与触摸路由会吃掉整屏事件（App 内按钮全失效），
/// 因此显示窗口设置 `_ignoresHitTest = YES`，拖拽 / 缩放改由一块普通 overlay 窗口承担。
final class FloatingLyricsManager: NSObject {

    static let shared = FloatingLyricsManager()

    /// 与系统 HUD 同级的窗口层级
    private let windowLevel: CGFloat = 10000010.0

    private var floatingWindow: FloatingSystemWindow?
    private var rootView: FloatingRootView?
    private var lyricsView: FloatingLyricsView?

    /// 交互层窗口（普通窗口，仅用于接收手势；不参与跨应用显示）
    private var overlayWindow: UIWindow?
    /// 交互层上的透明热区，位置尺寸与歌词框保持一致
    private var gestureView: UIView?

    private var hostingRegistered = false
    private var lyricsIndex: Int = -1
    private var isLocked = false
    private var keepAliveRemaining = 0

    private var pinchStartSize: CGSize?
    private var pinchStartFont: CGFloat = 16
    private var pinchStartSpan: (x: CGFloat, y: CGFloat)?

    /// 是否已成功注册为系统级（跨应用）窗口
    private(set) var isGlobalWindowReady = false

    var isShowing: Bool { floatingWindow?.isHidden == false }

    private override init() {
        super.init()
    }

    // MARK: - 显示 / 隐藏

    func show() {
        if let window = floatingWindow {
            window.isHidden = false
            overlayWindow?.isHidden = false
            applySettings()
            registerHostingIfNeeded()
            refreshPlaceholder()
            return
        }

        let screen = UIScreen.main.bounds

        // —— 显示窗口：系统级，跨应用可见，不接收触摸 ——
        let window = FloatingSystemWindow(frame: screen)
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        window.backgroundColor = .clear
        window.isOpaque = false
        if let scene = activeScene() {
            window.windowScene = scene
        }

        let root = FloatingRootView(frame: screen)
        root.backgroundColor = .clear
        root.isUserInteractionEnabled = true
        let viewController = UIViewController()
        viewController.view = root
        window.rootViewController = viewController

        let lyricView = FloatingLyricsView(
            frame: CGRect(origin: ConfigStore.shared.floatingOrigin,
                          size: ConfigStore.shared.floatingSize),
            fontSize: ConfigStore.shared.floatingFontSize
        )
        lyricView.backgroundColor = UIColor.black
            .withAlphaComponent(CGFloat(ConfigStore.shared.floatingOpacity))
        root.addSubview(lyricView)

        self.floatingWindow = window
        self.rootView = root
        self.lyricsView = lyricView

        // 让窗口可见但不长期抢占 key（否则会影响输入框等）
        let previousKey = currentKeyWindow()
        window.isHidden = false
        window.makeKeyAndVisible()
        previousKey?.makeKey()

        // —— 交互窗口：普通窗口，负责拖拽 / 缩放 / 双击 ——
        setupOverlayWindow(frame: lyricView.frame, scene: activeScene())

        setupGestures()
        registerHostingIfNeeded()
        observeNotifications()
        refreshPlaceholder()

        // 窗口刚显示时 contextId 可能尚未生成，稍后补注册一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.registerHostingIfNeeded()
        }
    }

    func hide() {
        if let window = floatingWindow, hostingRegistered {
            FloatingWindowHosting.unregister(window: window)
            hostingRegistered = false
            isGlobalWindowReady = false
        }
        floatingWindow?.isHidden = true
        overlayWindow?.isHidden = true
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    // MARK: - 交互窗口

    private func setupOverlayWindow(frame: CGRect, scene: UIWindowScene?) {
        let overlay = UIWindow(frame: UIScreen.main.bounds)
        overlay.windowLevel = UIWindow.Level.alert + 1
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        if let scene = scene {
            overlay.windowScene = scene
        }
        let root = FloatingRootView(frame: UIScreen.main.bounds)
        root.backgroundColor = .clear
        let vc = UIViewController()
        vc.view = root

        let hot = UIView(frame: frame)
        hot.backgroundColor = .clear
        hot.isUserInteractionEnabled = true
        root.addSubview(hot)

        overlay.rootViewController = vc
        overlay.isHidden = false

        self.overlayWindow = overlay
        self.gestureView = hot
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
    }

    /// 设置页改动后立即生效（尺寸 / 字号 / 透明度 / 位置）
    func applySettings() {
        guard let view = lyricsView, let hot = gestureView else { return }
        let size = ConfigStore.shared.floatingSize
        view.bounds = CGRect(origin: .zero, size: size)
        hot.bounds = CGRect(origin: .zero, size: size)
        let origin = ConfigStore.shared.floatingOrigin
        view.frame.origin = origin
        hot.frame.origin = origin
        view.fontSize = ConfigStore.shared.floatingFontSize
        if !isLocked {
            view.backgroundColor = UIColor.black
                .withAlphaComponent(CGFloat(ConfigStore.shared.floatingOpacity))
        }
        clampIntoScreen(view)
        hot.frame = view.frame
    }

    /// 实时更新悬浮歌词透明度
    func updateOpacity(_ value: Float) {
        ConfigStore.shared.floatingOpacity = value
        if !isLocked {
            lyricsView?.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(value))
        }
    }

    // MARK: - 系统级窗口注册

    private func registerHostingIfNeeded() {
        guard let window = floatingWindow, !hostingRegistered else { return }
        if FloatingWindowHosting.register(window: window, level: Double(windowLevel)) {
            hostingRegistered = true
            isGlobalWindowReady = true
            Logger.info("悬浮歌词：已注册系统级窗口，可跨应用显示")
        } else {
            Logger.warn("悬浮歌词：系统级窗口注册失败，退化为应用内悬浮")
        }
    }

    private func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: - 手势

    private func setupGestures() {
        guard let hot = gestureView else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        hot.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        hot.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        hot.addGestureRecognizer(doubleTap)
    }

    /// 手势改变了热区后，把歌词框同步到同一位置尺寸
    private func syncLyricsFrame() {
        guard let view = lyricsView, let hot = gestureView else { return }
        view.frame = hot.frame
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let hot = gestureView else { return }
        let translation = gesture.translation(in: hot.superview)
        hot.center = CGPoint(x: hot.center.x + translation.x,
                             y: hot.center.y + translation.y)
        gesture.setTranslation(.zero, in: hot.superview)
        syncLyricsFrame()

        if gesture.state == .ended {
            clampIntoScreen(hot)
            syncLyricsFrame()
            ConfigStore.shared.floatingOrigin = hot.frame.origin
        }
    }

    /// 捏合缩放：按双指的横向 / 纵向位移分量分别缩放宽高
    /// —— 竖直拉只改高度，横向拉只改宽度，斜着拉等比缩放
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isLocked, let hot = gestureView else { return }
        let screenW = UIScreen.main.bounds.width

        switch gesture.state {
        case .began:
            pinchStartSize = hot.bounds.size
            pinchStartFont = ConfigStore.shared.floatingFontSize
            pinchStartSpan = pinchSpan(gesture)

        case .changed:
            guard let start = pinchStartSize else { break }
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

            hot.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let ratio = height / max(1, start.height)
            lyricsView?.fontSize = clamp(pinchStartFont * ratio, min: 10, max: 34)
            syncLyricsFrame()

        case .ended, .cancelled:
            ConfigStore.shared.floatingSize = hot.bounds.size
            ConfigStore.shared.floatingFontSize = lyricsView?.fontSize ?? ConfigStore.shared.floatingFontSize
            clampIntoScreen(hot)
            syncLyricsFrame()
            ConfigStore.shared.floatingOrigin = hot.frame.origin
            pinchStartSize = nil
            pinchStartSpan = nil

        default:
            pinchStartSize = nil
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

    /// 保证悬浮框完整留在屏幕内
    private func clampIntoScreen(_ view: UIView) {
        let screen = UIScreen.main.bounds
        let maxX = Swift.max(6, screen.width - view.bounds.width - 6)
        let maxY = Swift.max(6, screen.height - view.bounds.height - 6)
        view.frame.origin = CGPoint(x: clamp(view.frame.origin.x, min: 6, max: maxX),
                                    y: clamp(view.frame.origin.y, min: 6, max: maxY))
    }

    // MARK: - 后台保活

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(lyricsLineChanged(_:)),
                           name: .lyricsLineChanged, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
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

    @objc private func appDidEnterBackground() {
        guard isShowing else { return }
        keepVisible()
        // 退后台后系统可能重置窗口状态，短时间内补几次
        keepAliveRemaining = 6
        keepAliveStep()
    }

    @objc private func appDidBecomeActive() {
        guard isShowing else { return }
        overlayWindow?.isHidden = false
        keepVisible()
    }

    private func keepVisible() {
        guard let window = floatingWindow, isShowing else { return }
        window.isHidden = false
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        registerHostingIfNeeded()
    }

    private func keepAliveStep() {
        guard keepAliveRemaining > 0 else { return }
        keepAliveRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isShowing else { return }
            self.keepVisible()
            self.keepAliveStep()
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
