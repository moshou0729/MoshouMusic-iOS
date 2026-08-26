import UIKit

/// 收起后的迷你播放控制
/// - 可拖动的小浮层：中心一个圆角正方形按钮（播放/暂停），正方形「周长描边」随播放进度沿四边走动
/// - 拖动可移到任意位置，松手就近吸附到左 / 右边（保留落点高度）；
///   右滑或上滑展开回完整播放条；点中心按钮 = 播放 / 暂停
class CollapsedPlayerControl: UIView {

    /// 右滑 / 上滑展开回完整播放条
    var onExpand: (() -> Void)?

    private let squareView = UIView()
    private let playButton = UIButton(type: .system)
    private let ringLayer = CAShapeLayer()

    /// 由 MainTabBarController 注入的定位约束（leading 控制左右，bottom 控制上下）
    var positionLeading: NSLayoutConstraint?
    var positionBottom: NSLayoutConstraint?

    private var panGesture: UIPanGestureRecognizer?
    private var dragStartFrame: CGRect = .zero
    private var dragStartLead: CGFloat = 0
    private var dragStartBottom: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        bindPlayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        bindPlayer()
    }

    // MARK: - UI

    private func setupUI() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        // 正方形周长描边进度（绕 squareView 外缘一圈，随播放进度沿周长走）
        ringLayer.fillColor = nil
        ringLayer.strokeColor = Theme.primary.cgColor
        ringLayer.lineWidth = 3
        ringLayer.lineCap = .round
        ringLayer.strokeEnd = 0
        layer.addSublayer(ringLayer)

        // 中心正方形按钮
        squareView.backgroundColor = Theme.cardBg
        squareView.layer.cornerRadius = 14
        squareView.layer.shadowColor = UIColor.black.cgColor
        squareView.layer.shadowOpacity = 0.12
        squareView.layer.shadowOffset = CGSize(width: 0, height: 2)
        squareView.layer.shadowRadius = 6
        squareView.isUserInteractionEnabled = false
        addSubview(squareView)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = Theme.primary
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        addSubview(playButton)

        setupConstraints()
    }

    /// 配置拖动 + 展开手势（在约束注入后由 MainTabBarController 调用）
    func configureDrag() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        panGesture = pan

        let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        rightSwipe.direction = .right
        addGestureRecognizer(rightSwipe)

        // 先判定「右滑」手势，确认不是「展开（右滑）」后才交给拖动，
        // 让上下 / 左方向都能自由拖动换位；上滑不再绑展开，避免与「上拖换位」冲突
        pan.require(toFail: rightSwipe)
    }

    private func setupConstraints() {
        [squareView, playButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            squareView.widthAnchor.constraint(equalToConstant: 52),
            squareView.heightAnchor.constraint(equalToConstant: 52),
            squareView.centerXAnchor.constraint(equalTo: centerXAnchor),
            squareView.centerYAnchor.constraint(equalTo: centerYAnchor),

            playButton.widthAnchor.constraint(equalToConstant: 46),
            playButton.heightAnchor.constraint(equalToConstant: 46),
            playButton.centerXAnchor.constraint(equalTo: squareView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: squareView.centerYAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 正方形周长描边：以 squareView 外缘为基准画一圈圆角矩形，进度沿周长走动
        let sq: CGFloat = 52
        let pad = (bounds.width - sq) / 2
        let rect = CGRect(
            x: pad - 1.5,
            y: pad - 1.5,
            width: sq + 3,
            height: sq + 3
        )
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 14)
        ringLayer.path = path.cgPath
    }

    // MARK: - 拖动 + 就近吸附

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let sup = self.superview,
              let leadC = positionLeading,
              let bottomC = positionBottom else { return }

        let size = bounds.width
        let w = sup.bounds.width
        let h = sup.bounds.height
        let insets = sup.safeAreaInsets
        let leftMargin: CGFloat = 0     // 左侧贴边（无空隙）
        let rightMargin: CGFloat = 0    // 右侧同样贴边，与左侧对称无空隙
        let topMin = insets.top + 8
        let topMax = h - insets.bottom - 8 - size

        switch g.state {
        case .began:
            dragStartFrame = self.frame
            dragStartLead = leadC.constant
            dragStartBottom = bottomC.constant

        case .changed:
            let t = g.translation(in: sup)
            var x = dragStartFrame.origin.x + t.x
            var y = dragStartFrame.origin.y + t.y
            x = min(max(x, leftMargin), w - rightMargin - size)
            y = min(max(y, topMin), topMax)
            leadC.constant = x
            // bottom 约束：bottomAnchor = safeAreaBottom + K
            // → K = (方块底边 y) - safeAreaBottom = (y + size) - (h - insets.bottom)
            bottomC.constant = (y + size) - (h - insets.bottom)
            UIView.performWithoutAnimation { sup.layoutIfNeeded() }

        case .ended, .cancelled, .failed:
            // 就近吸附：以中心 x 判断靠左还是靠右，保留落点高度
            let midX = self.frame.midX
            let snapX = (midX < w / 2) ? leftMargin : (w - rightMargin - size)
            let snapY = min(max(self.frame.origin.y, topMin), topMax)
            leadC.constant = snapX
            bottomC.constant = (snapY + size) - (h - insets.bottom)
            // 弹性吸附动画
            UIView.animate(withDuration: 0.32, delay: 0,
                           usingSpringWithDamping: 0.72, initialSpringVelocity: 0.6) {
                sup.layoutIfNeeded()
            }

        default:
            break
        }
    }

    @objc private func handleSwipeRight() { onExpand?() }

    // MARK: - 播放器绑定

    private func bindPlayer() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged(_:)),
            name: .playerStateChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(timeChanged(_:)),
            name: .playerTimeChanged, object: nil
        )
    }

    @objc private func stateChanged(_ notification: Notification) {
        guard let state = notification.object as? PlayerState else { return }
        let playing = state.isPlaying
        playButton.setImage(
            UIImage(systemName: playing ? "pause.fill" : "play.fill"),
            for: .normal
        )
    }

    @objc private func timeChanged(_ notification: Notification) {
        guard let current = notification.userInfo?["current"] as? Double,
              let duration = notification.userInfo?["duration"] as? Double,
              duration > 0 else { return }
        let p = min(1, max(0, current / duration))
        ringLayer.strokeEnd = CGFloat(p)
    }

    // MARK: - Actions

    @objc private func playTapped() {
        PlayerManager.shared.togglePlayPause()
    }
}
