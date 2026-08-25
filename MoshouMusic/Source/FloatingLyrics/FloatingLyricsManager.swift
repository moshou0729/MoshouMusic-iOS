import UIKit

/// 系统级悬浮歌词窗口 — TrollStore 专属能力
/// 利用 TrollStore 权限创建跨应用悬浮窗
class FloatingLyricsManager: NSObject {

    static let shared = FloatingLyricsManager()

    private var floatingWindow: UIWindow?
    private var lyricsView: FloatingLyricsView?
    private var panGesture: UIPanGestureRecognizer?

    private var isLocked = false
    private var opacity: CGFloat {
        get { CGFloat(ConfigStore.shared.floatingOpacity) }
        set { ConfigStore.shared.floatingOpacity = Float(newValue) }
    }

    private var windowFrame: CGRect = CGRect(x: 20, y: 200, width: 340, height: 56)
    private var lastPressLocation: CGPoint?

    var isShowing: Bool {
        return floatingWindow?.isHidden == false
    }

    private override init() {
        super.init()
    }

    // MARK: - 显示/隐藏

    func show() {
        guard floatingWindow == nil else {
            floatingWindow?.isHidden = false
            return
        }

        // 方案: UIWindow + windowLevel
        // TrollStore 权限下，高级别 window 可以悬浮在其他应用之上
        let window = FloatingWindow(frame: windowFrame)
        window.windowLevel = UIWindow.Level.alert + 1
        window.backgroundColor = .clear
        window.isOpaque = false

        // 关联当前激活的 windowScene，否则 iOS 13+ 上第二窗口可能不显示
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            window.windowScene = scene
        }

        let viewController = UIViewController()
        let view = FloatingLyricsView(frame: window.bounds)
        view.backgroundColor = UIColor.black.withAlphaComponent(opacity)
        view.layer.cornerRadius = 16
        view.layer.masksToBounds = true
        viewController.view = view

        // 初始显示当前歌曲名，避免一直停在占位文案让人误以为没显示
        if let song = PlayerManager.shared.currentSong {
            view.updateLyrics(text: song.name, translation: song.singer)
        }

        window.rootViewController = viewController
        window.isHidden = false
        window.makeKeyAndVisible()

        floatingWindow = window
        lyricsView = view

        setupGesture()
        observeLyrics()
    }

    func hide() {
        floatingWindow?.isHidden = true
    }

    func toggle() {
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    /// 实时更新悬浮歌词透明度
    func updateOpacity(_ value: Float) {
        opacity = CGFloat(value)
        if !isLocked, let view = lyricsView {
            view.backgroundColor = UIColor.black.withAlphaComponent(opacity)
        }
    }

    // MARK: - 手势

    private func setupGesture() {
        guard let view = lyricsView else { return }

        // 拖拽
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)
        panGesture = pan

        // 双击锁定/解锁
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // 长按调整透明度
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        view.addGestureRecognizer(longPress)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isLocked, let window = floatingWindow else { return }

        let translation = gesture.translation(in: window)
        window.center = CGPoint(
            x: window.center.x + translation.x,
            y: window.center.y + translation.y
        )
        gesture.setTranslation(.zero, in: window)

        if gesture.state == .ended {
            windowFrame = window.frame

            // 边缘吸附
            snapToEdge(window)
        }
    }

    private func snapToEdge(_ window: UIWindow) {
        let screenWidth = UIScreen.main.bounds.width
        let centerX = window.center.x

        let targetX: CGFloat
        if centerX < screenWidth / 2 {
            targetX = windowFrame.width / 2 + 8
        } else {
            targetX = screenWidth - windowFrame.width / 2 - 8
        }

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.5, options: .curveEaseOut) {
            window.center.x = targetX
        } completion: { _ in
            self.windowFrame = window.frame
        }
    }

    @objc private func handleDoubleTap() {
        isLocked.toggle()
        lyricsView?.updateLockState(isLocked)

        // 锁定后降低透明度
        UIView.animate(withDuration: 0.2) {
            if self.isLocked {
                self.lyricsView?.backgroundColor = UIColor.black.withAlphaComponent(0.3)
            } else {
                self.lyricsView?.backgroundColor = UIColor.black.withAlphaComponent(self.opacity)
            }
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            lastPressLocation = location
        case .changed:
            guard let last = lastPressLocation else { break }
            let dy = location.y - last.y
            lastPressLocation = location
            opacity = max(0.3, min(1.0, opacity + dy / 500))
            if !isLocked {
                lyricsView?.backgroundColor = UIColor.black.withAlphaComponent(opacity)
            }
        default:
            lastPressLocation = nil
        }
    }

    // MARK: - 歌词监听

    private func observeLyrics() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(lyricsLineChanged(_:)),
            name: .lyricsLineChanged, object: nil
        )
    }

    @objc private func lyricsLineChanged(_ notification: Notification) {
        guard let line = notification.object as? LRCLine else { return }
        DispatchQueue.main.async {
            self.lyricsView?.updateLyrics(text: line.text, translation: line.translation)
        }
    }
}

// MARK: - 触摸穿透窗口

class FloatingWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event) else {
            return nil
        }
        // 透明区域穿透到下层应用
        if result === self.rootViewController?.view {
            return nil
        }
        return result
    }
}
