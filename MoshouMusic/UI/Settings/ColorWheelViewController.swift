import UIKit

/// v1.0.141：自定义色彩圆盘 —— 外圈色相环 + 内部饱和度/亮度方盘（HSV）。
/// 拖动实时回调（悬浮窗本地即时变色），松手回调（触发 SB 全量重合成）。
final class ColorWheelViewController: UIViewController {

    /// 实时选色回调（RGB hex）
    var onColorChanged: ((UInt32) -> Void)?
    /// 一次选择结束（松手 / 点完成）回调
    var onFinished: (() -> Void)?

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 1

    private let ringView = HueRingView()
    private let svView = SVSquareView()
    private let previewDot = UIView()
    private let hexLabel = UILabel()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自定义颜色"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))

        let initial = UIColor(hex: ConfigStore.shared.floatingBgColorHex)
        var a: CGFloat = 0
        initial.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a)

        ringView.translatesAutoresizingMaskIntoConstraints = false
        svView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ringView)
        view.addSubview(svView)

        previewDot.layer.cornerRadius = 16
        previewDot.layer.borderWidth = 1
        previewDot.layer.borderColor = Theme.outlineVariant.cgColor
        previewDot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewDot)

        hexLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        hexLabel.textColor = .secondaryLabel
        hexLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hexLabel)

        let side = min(UIScreen.main.bounds.width - 80, 280)
        NSLayoutConstraint.activate([
            ringView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            ringView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ringView.widthAnchor.constraint(equalToConstant: side),
            ringView.heightAnchor.constraint(equalToConstant: side),

            svView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            svView.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
            svView.widthAnchor.constraint(equalTo: ringView.widthAnchor, multiplier: 0.62),
            svView.heightAnchor.constraint(equalTo: svView.widthAnchor),

            previewDot.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 24),
            previewDot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            previewDot.widthAnchor.constraint(equalToConstant: 32),
            previewDot.heightAnchor.constraint(equalToConstant: 32),

            hexLabel.centerYAnchor.constraint(equalTo: previewDot.centerYAnchor),
            hexLabel.leadingAnchor.constraint(equalTo: previewDot.trailingAnchor, constant: 14),
        ])

        syncFromHSV()
        bindGestures()
    }

    @objc private func doneTapped() {
        onFinished?()
        dismiss(animated: true)
    }

    // MARK: - 手势

    private func bindGestures() {
        let ringPan = UIPanGestureRecognizer(target: self, action: #selector(handleRing(_:)))
        ringPan.addTarget(self, action: #selector(handleRingEnd(_:)))
        let ringTap = UITapGestureRecognizer(target: self, action: #selector(handleRing(_:)))
        ringView.addGestureRecognizer(ringPan)
        ringView.addGestureRecognizer(ringTap)

        let svPan = UIPanGestureRecognizer(target: self, action: #selector(handleSV(_:)))
        let svTap = UITapGestureRecognizer(target: self, action: #selector(handleSV(_:)))
        svView.addGestureRecognizer(svPan)
        svView.addGestureRecognizer(svTap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTouchEnd), name: UIApplication.willResignActiveNotification,
            object: nil)
    }

    @objc private func handleRingEnd(_ g: UIGestureRecognizer) {
        if g.state == .ended { touchEnded() }
    }

    @objc private func handleTouchEnd() {
        touchEnded()
    }

    @objc private func handleRing(_ g: UIGestureRecognizer) {
        let p = g.location(in: ringView)
        let center = CGPoint(x: ringView.bounds.midX, y: ringView.bounds.midY)
        let dx = p.x - center.x, dy = p.y - center.y
        let r = sqrt(dx * dx + dy * dy)
        let outer = min(ringView.bounds.width, ringView.bounds.height) / 2
        let inner = outer * HueRingView.innerRatio
        guard r >= inner - 10, r <= outer + 10 else { return }
        var angle = atan2(dy, dx) / (2 * .pi)          // -0.5~0.5
        if angle < 0 { angle += 1 }
        hue = angle
        syncFromHSV()
        if g.state == .ended { touchEnded() }
    }

    @objc private func handleSV(_ g: UIGestureRecognizer) {
        let p = g.location(in: svView)
        guard svView.bounds.width > 0 else { return }
        saturation = min(1, max(0, p.x / svView.bounds.width))
        brightness = min(1, max(0, 1 - p.y / svView.bounds.height))
        syncFromHSV()
        if g.state == .ended { touchEnded() }
    }

    private func touchEnded() {
        onFinished?()
    }

    // MARK: - 状态

    private func syncFromHSV() {
        let color = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        var r: CGFloat = 0, gg: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &gg, blue: &b, alpha: &a)
        let hex = (UInt32(r * 255) << 16) | (UInt32(gg * 255) << 8) | UInt32(b * 255)
        ringView.hue = hue
        svView.hue = hue
        svView.saturation = saturation
        svView.brightness = brightness
        previewDot.backgroundColor = color
        hexLabel.text = String(format: "#%06X", hex)
        onColorChanged?(hex)
    }
}

// MARK: - 色相环（一次渲染成位图，拖动只动游标）

final class HueRingView: UIView {

    static let innerRatio: CGFloat = 0.78
    var hue: CGFloat = 0 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2
        let inner = outer * Self.innerRatio
        let width = outer - inner
        for deg in stride(from: 0, to: 360, by: 2) {
            let angle = CGFloat(deg) * .pi / 180
            let h = CGFloat(deg) / 360
            ctx.setStrokeColor(UIColor(hue: h, saturation: 1, brightness: 1, alpha: 1).cgColor)
            ctx.setLineWidth(width + 1)
            let from = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let to = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
            ctx.beginPath()
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
        }
        // 游标
        let thumbAngle = hue * 2 * .pi
        let tp = CGPoint(x: center.x + cos(thumbAngle) * (inner + width / 2),
                         y: center.y + sin(thumbAngle) * (inner + width / 2))
        ctx.setFillColor(UIColor(white: 1, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: tp.x - 7, y: tp.y - 7, width: 14, height: 14))
        ctx.setFillColor(UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: tp.x - 4.5, y: tp.y - 4.5, width: 9, height: 9))
    }
}

// MARK: - 饱和度/亮度方盘

final class SVSquareView: UIView {

    var hue: CGFloat = 0 { didSet { updateGradients() } }
    var saturation: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var brightness: CGFloat = 1 { didSet { setNeedsDisplay() } }

    private let whiteLayer = CAGradientLayer()
    private let blackLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        layer.cornerRadius = 8
        layer.masksToBounds = true
        whiteLayer.startPoint = CGPoint(x: 0, y: 0.5)
        whiteLayer.endPoint = CGPoint(x: 1, y: 0.5)
        blackLayer.startPoint = CGPoint(x: 0.5, y: 0)
        blackLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(whiteLayer)
        layer.addSublayer(blackLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateGradients() {
        let pure = UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        whiteLayer.colors = [UIColor.white.cgColor, pure.cgColor]
        blackLayer.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        whiteLayer.frame = bounds
        blackLayer.frame = bounds
        CATransaction.commit()
        updateGradients()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = CGPoint(x: bounds.width * saturation, y: bounds.height * (1 - brightness))
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: p.x - 10.5, y: p.y - 10.5, width: 21, height: 21))
    }
}
