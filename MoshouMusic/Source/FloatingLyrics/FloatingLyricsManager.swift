import UIKit

/// 系统级悬浮歌词窗口 — TrollStore 专属能力
///
/// 方案照搬已真机验证的参考实现（TrollSpeed / 墨守提词器）：
/// 1. FloatingSystemWindow 覆写 UIWindow 私有方法，脱离 WindowServer 托管；
/// 2. dlopen SpringBoardServices 后，把窗口 contextId 注册进 SpringBoard
///    系统窗口树（跨应用 / 主屏 / 锁屏显示的关键）；
/// 3. 注册带 0.3s × 4 次重试（contextId 要等下一个 runloop 才生成），
///    成功后绝不再动 —— 反复重注册反而会让 SpringBoard 把窗口移除；
/// 4. 失败降级为应用内悬浮，设置页展示诊断串。
///
/// 触摸：单窗口方案。根视图空白处 hitTest 返回 nil（点击穿透到下层应用 /
/// App 主窗口），歌词框区域自身接收拖拽 / 缩放手势。
final class FloatingLyricsManager: NSObject {

    static let shared = FloatingLyricsManager()

    /// 与系统 HUD 同级的窗口层级
    private let windowLevel: CGFloat = 10000010.0

    private var floatingWindow: FloatingSystemWindow?
    private var rootView: FloatingRootView?
    private var lyricsView: FloatingLyricsView?

    private var hostingRegistered = false
    private var registerAttempts = 0
    private var lyricsIndex: Int = -1
    private var isLocked = false

    private var pinchStartSize: CGSize?
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

        let screen = UIScreen.main.bounds

        let window = FloatingSystemWindow(frame: screen)
        window.windowLevel = UIWindow.Level(rawValue: windowLevel)
        window.backgroundColor = .clear
        window.isOpaque = false
        if let scene = activeScene() {
            window.windowScene = scene
        }

        // 全屏 window + 内部小歌词视图（同参考实现），空白处点击穿透
        let root = FloatingRootView(frame: screen)
        root.backgroundColor = .clear
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
        lyricView.isUserInteractionEnabled = true
        root.addSubview(lyricView)

        self.floatingWindow = window
        self.rootView = root
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
    func applySettings() {
        guard let view = lyricsView else { return }
        view.bounds = CGRect(origin: .zero, size: ConfigStore.shared.floatingSize)
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

    // MARK: - 手势（直接挂在歌词视图上）

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

    /// 捏合缩放：按双指的横向 / 纵向位移分量分别缩放宽高
    /// —— 竖直拉只改高度，横向拉只改宽度，斜着拉等比缩放
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isLocked, let view = lyricsView else { return }
        let screenW = UIScreen.main.bounds.width

        switch gesture.state {
        case .began:
            pinchStartSize = view.bounds.size
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

            view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let ratio = height / max(1, start.height)
            view.fontSize = clamp(pinchStartFont * ratio, min: 10, max: 34)

        case .ended, .cancelled:
            ConfigStore.shared.floatingSize = view.bounds.size
            ConfigStore.shared.floatingFontSize = view.fontSize
            clampIntoScreen(view)
            ConfigStore.shared.floatingOrigin = view.frame.origin
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
