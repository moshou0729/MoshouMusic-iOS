import UIKit

/// 收起后的迷你播放控制
/// - 中心一个圆角正方形按钮（播放/暂停），正方形「周长描边」随播放进度沿四边走动
/// - 长按 + 拖动：上下左右任意换位，松手就近吸附到左 / 右边（保留落点高度）
/// - 短滑展开：吸附左侧时向右滑、吸附右侧时向左滑，展开回完整播放条
/// - 单击 = 播放 / 暂停
class CollapsedPlayerControl: UIView {

    /// 右滑 / 上滑展开回完整播放条
    var onExpand: (() -> Void)?

    private let squareView = UIView()
    private let playButton = UIButton(type: .system)
    private let ringLayer = CAShapeLayer()

    /// 由 MainTabBarController 注入的定位约束（leading 控制左右，bottom 控制上下）
    var positionLeading: NSLayoutConstraint?
    var positionBottom: NSLayoutConstraint?

    private var longPress: UILongPressGestureRecognizer!
    private var tapGesture: UITapGestureRecognizer!
    private var leftSwipe: UISwipeGestureRecognizer!
    private var rightSwipe: UISwipeGestureRecognizer!

    /// 当前吸附在哪一侧（决定「短滑展开」的方向）
    private var isLeftSide = true

    /// 长按拖动起点
    private var lpStartFrame: CGRect = .zero
    private var lpStartLead: CGFloat = 0
    private var lpStartBottom: CGFloat = 0

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
        playButton.isUserInteractionEnabled = false   // 点击交给整块的 tap 手势统一处理
        addSubview(playButton)

        setupConstraints()
    }

    /// 配置手势（在约束注入后由 MainTabBarController 调用）
    /// - 单击：播放 / 暂停
    /// - 长按 + 拖动：上下左右任意方向换位（就近吸附到左 / 右侧）
    /// - 短滑：依当前吸附侧决定展开方向（左吸附→右滑展开；右吸附→左滑展开）
    func configureGestures() {
        // 长按 = 进入拖动态
        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.18
        longPress.allowableMovement = 12
        addGestureRecognizer(longPress)

        // 单击 = 播放 / 暂停（长按优先，避免拖动 / 长按误触播放）
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.require(toFail: longPress)
        addGestureRecognizer(tapGesture)

        // 短滑动 = 展开（方向取决于吸附侧）
        leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        leftSwipe.direction = .left
        leftSwipe.require(toFail: longPress)   // 先判定是否长按拖动，避免冲突
        addGestureRecognizer(leftSwipe)

        rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        rightSwipe.direction = .right
        rightSwipe.require(toFail: longPress)
        addGestureRecognizer(rightSwipe)
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

    // MARK: - 长按拖动换位 + 就近吸附 + 短滑展开

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let sup = self.superview,
              let leadC = positionLeading,
              let bottomC = positionBottom else { return }

        let size = bounds.width
        let w = sup.bounds.width
        let h = sup.bounds.height
        let insets = sup.safeAreaInsets
        let margin: CGFloat = 0          // 左右都贴边，无空隙
        let topMin = insets.top + 8
        let topMax = h - insets.bottom - 8 - size

        switch g.state {
        case .began:
            lpStartFrame = self.frame
            lpStartLead = leadC.constant
            lpStartBottom = bottomC.constant
            // 抓取反馈：轻微放大
            UIView.animate(withDuration: 0.12) { self.transform = CGAffineTransform(scaleX: 1.12, y: 1.12) }

        case .changed:
            let t = g.translation(in: sup)
            var x = lpStartFrame.origin.x + t.x
            var y = lpStartFrame.origin.y + t.y
            x = min(max(x, margin), w - margin - size)
            y = min(max(y, topMin), topMax)
            leadC.constant = x
            // bottom 约束：bottomAnchor = safeAreaBottom + K
            // → K = (方块底边 y) - safeAreaBottom = (y + size) - (h - insets.bottom)
            bottomC.constant = (y + size) - (h - insets.bottom)
            UIView.performWithoutAnimation { sup.layoutIfNeeded() }

        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.12) { self.transform = .identity }
            snapToNearestEdge()

        default:
            break
        }
    }

    /// 松手后就近吸附到左 / 右侧（保留落点高度），并记录当前吸附侧
    private func snapToNearestEdge() {
        guard let sup = superview,
              let leadC = positionLeading,
              let bottomC = positionBottom else { return }

        let size = bounds.width
        let w = sup.bounds.width
        let h = sup.bounds.height
        let insets = sup.safeAreaInsets
        let margin: CGFloat = 0
        let topMin = insets.top + 8
        let topMax = h - insets.bottom - 8 - size

        let midX = self.frame.midX
        isLeftSide = midX < w / 2
        let snapX = isLeftSide ? margin : (w - margin - size)
        let snapY = min(max(self.frame.origin.y, topMin), topMax)
        leadC.constant = snapX
        bottomC.constant = (snapY + size) - (h - insets.bottom)
        UIView.animate(withDuration: 0.32, delay: 0,
                       usingSpringWithDamping: 0.72, initialSpringVelocity: 0.6) {
            sup.layoutIfNeeded()
        }
    }

    @objc private func handleSwipeLeft() {
        // 吸附在右侧时，短向左滑 = 展开
        if !isLeftSide { onExpand?() }
    }

    @objc private func handleSwipeRight() {
        // 吸附在左侧时，短向右滑 = 展开
        if isLeftSide { onExpand?() }
    }

    @objc private func handleTap() {
        PlayerManager.shared.togglePlayPause()
    }

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
}
