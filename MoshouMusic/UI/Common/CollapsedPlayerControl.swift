import UIKit

/// 收起后的迷你播放控制
/// - 左下角小浮层：中心一个圆角正方形按钮（播放/暂停），四周一圈动态进度环
/// - 右滑展开回完整播放条；点中心按钮 = 播放/暂停
class CollapsedPlayerControl: UIView {

    /// 右滑展开回完整播放条
    var onExpand: (() -> Void)?

    private let squareView = UIView()
    private let playButton = UIButton(type: .system)
    private let ringLayer = CAShapeLayer()

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

        // 环形进度（绘制在 square 下方，绕中心一圈）
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

        // 右滑展开
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        swipe.direction = .right
        addGestureRecognizer(swipe)

        setupConstraints()
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
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let radius = (min(bounds.width, bounds.height) - ringLayer.lineWidth) / 2 - 2
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -CGFloat.pi / 2,
            endAngle: CGFloat.pi * 1.5,
            clockwise: true
        )
        ringLayer.path = path.cgPath
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

    @objc private func playTapped() {
        PlayerManager.shared.togglePlayPause()
    }

    @objc private func handleSwipeRight() {
        onExpand?()
    }
}
