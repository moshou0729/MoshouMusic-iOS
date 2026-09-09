import UIKit

/// 系统级悬浮歌词窗口 — TrollStore 专属能力
///
/// 三层保障，确保切到别的应用后依然悬浮：
/// 1. FloatingSystemWindow 覆写 UIWindow 私有方法（_isSystemWindow / _isSecure 等），
///    让 backboardd 按「系统窗口」渲染，应用退后台也不隐藏；
/// 2. 通过 SBSAccessibilityWindowHostingController 把窗口注册到 SpringBoard 的
///    辅助功能窗口托管服务 —— 这才是跨应用（主屏 / 其他 App / 锁屏）显示的关键；
/// 3. 退后台后多次「保活」重试：重新声明窗口层级并补注册。
final class FloatingLyricsManager: NSObject {

    static let shared = FloatingLyricsManager()

    /// 与系统 HUD 同级的窗口层级
    private let windowLevel: CGFloat = 10000010.0

    private var floatingWindow: FloatingSystemWindow?
    private var rootView: FloatingRootView?
    private var lyricsView: FloatingLyricsView?

    private var hostingRegistered = false
    private var lyricsIndex: Int = -1
    private var isLocked = false
    private var keepAliveRemaining = 0

    private var pinchStartSize: CGSize?
    private var pinchStartFont: CGFloat = 16

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
            applySettings()
            registerHostingIfNeeded()
            refreshPlaceholder()
            return
        }

        let screen = UIScreen.main.bounds
        let window = FloatingSystemWindow(frame: screen)
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        window.backgroundColor = .clear
        window.isOpaque = false
        // iOS 13+ 需要关联 scene，否则窗口不显示
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
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
        guard let window = floatingWindow else { return }
        if hostingRegistered {
            FloatingWindowHosting.unregister(window: window)
            hostingRegistered = false
            isGlobalWindowReady = false
        }
        window.isHidden = true
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    /// 设置页改动后立即生效（尺寸 / 字号 / 透明度 / 位置）
    func applySettings() {
        guard let view = lyricsView else { return }
        let size = ConfigStore.shared.floatingSize
        view.bounds = CGRect(origin: .zero, size: size)
        view.frame.origin = ConfigStore.shared.floatingOrigin
        view.fontSize = ConfigStore.shared.floatingFontSize
        if !isLocked {
            view.backgroundColor = UIColor.black
                .withAlphaComponent(CGFloat(ConfigStore.shared.floatingOpacity))
        }
        clampIntoScreen(view)
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
        guard let view = lyricsView else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        view.isUserInteractionEnabled = true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let view = lyricsView else { return }
        let translation = gesture.translation(in: view.superview)
        view.center = CGPoint(x: view.center.x + translation.x,
                              y: view.center.y + translation.y)
        gesture.setTranslation(.zero, in: view.superview)

        if gesture.state == .ended {
            clampIntoScreen(view)
            ConfigStore.shared.floatingOrigin = view.frame.origin
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isLocked, let view = lyricsView else { return }

        switch gesture.state {
        case .began:
            pinchStartSize = view.bounds.size
            pinchStartFont = ConfigStore.shared.floatingFontSize
        case .changed:
            guard let start = pinchStartSize else { break }
            let width = clamp(start.width * gesture.scale, min: 140,
                              max: UIScreen.main.bounds.width - 16)
            let height = clamp(start.height * gesture.scale, min: 72, max: 360)
            view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let ratio = height / max(1, start.height)
            view.fontSize = clamp(pinchStartFont * ratio, min: 10, max: 34)
        case .ended, .cancelled:
            ConfigStore.shared.floatingSize = view.bounds.size
            ConfigStore.shared.floatingFontSize = view.fontSize
            clampIntoScreen(view)
            ConfigStore.shared.floatingOrigin = view.frame.origin
            pinchStartSize = nil
        default:
            pinchStartSize = nil
        }
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

    /// 当前歌曲标识，用于判断换歌
    private var lastSongKey: String?

    @objc private func appDidEnterBackground() {
        guard isShowing else { return }
        keepVisible()
        // 退后台后系统可能重置窗口状态，短时间内补几次
        keepAliveRemaining = 6
        keepAliveStep()
    }

    @objc private func appDidBecomeActive() {
        guard isShowing else { return }
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
