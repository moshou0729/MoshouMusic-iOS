import UIKit

/// v1.0.154：桌面悬浮窗播放控制条 —— 上一首 / 播放·暂停 / 下一首
///
/// 设计要点：
/// - **半透明黑色胶囊 + 白色 SF Symbol**，浮在悬浮窗顶部；高度随悬浮窗尺寸缩放（22~32pt）。
/// - 只负责「长得对 + 把点按转成闭包」；播放状态由 FloatingLyricsManager 单向同步
///   （`isPlaying` 决定中间按钮是 pause 还是 play 图标）。
/// - 点按**不参与**窗口拖动 / 捏合 / 折叠手势：由 manager 的
///   `gestureRecognizer(_:shouldReceive:)` 把控制条区域内的触摸从手势识别器里剔除。
/// - 折叠态（48×48 圆点）由 FloatingLyricsView 统一隐藏。
final class FloatingControlBar: UIView {

    /// 上一首
    var onPrevious: (() -> Void)?
    /// 播放 / 暂停
    var onToggle: (() -> Void)?
    /// 下一首
    var onNext: (() -> Void)?

    private let prevButton = FloatingControlBar.makeIconButton("backward.fill", label: "上一首")
    private let toggleButton = FloatingControlBar.makeIconButton("pause.fill", label: "播放暂停")
    private let nextButton = FloatingControlBar.makeIconButton("forward.fill", label: "下一首")

    /// 图标实际应用过的字号（避免每次 layout 都重建 UIImage）
    private var appliedPointSize: CGFloat = 0

    /// 播放器当前是否在播 —— 决定中间按钮显示 pause / play
    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            applyToggleIcon()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // 半透明底：悬浮窗本身已是半透明色块，这里再压一层保证图标压在亮色封面上也看得清
        backgroundColor = UIColor.black.withAlphaComponent(0.32)
        layer.masksToBounds = true
        isUserInteractionEnabled = true

        prevButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        addSubview(prevButton)
        addSubview(toggleButton)
        addSubview(nextButton)
        applyIconSizes()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2

        let buttons = [prevButton, toggleButton, nextButton]
        let gap: CGFloat = 2
        let count = CGFloat(buttons.count)
        let width = max(0, (bounds.width - gap * (count - 1)) / count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * (width + gap), y: 0,
                                  width: width, height: bounds.height)
        }

        // 图标随条高缩放（9~17pt），只在尺寸真变了才重建图片
        let pointSize = max(9, min(17, bounds.height * 0.46))
        if abs(pointSize - appliedPointSize) > 0.5 {
            appliedPointSize = pointSize
            applyIconSizes()
        }
    }

    // MARK: - 图标

    private func applyIconSizes() {
        let size = appliedPointSize > 0 ? appliedPointSize : 13
        prevButton.setImage(Self.icon("backward.fill", pointSize: size), for: .normal)
        nextButton.setImage(Self.icon("forward.fill", pointSize: size), for: .normal)
        applyToggleIcon()
    }

    private func applyToggleIcon() {
        let size = appliedPointSize > 0 ? appliedPointSize : 13
        let name = isPlaying ? "pause.fill" : "play.fill"
        toggleButton.setImage(Self.icon(name, pointSize: size), for: .normal)
    }

    // MARK: - 动作

    @objc private func previousTapped() { feedback(); onPrevious?() }
    @objc private func toggleTapped() { feedback(); onToggle?() }
    @objc private func nextTapped() { feedback(); onNext?() }

    /// 轻震动（后台 / 挂起时不生效，失败也无副作用）
    private func feedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    // MARK: - 工厂

    private static func makeIconButton(_ name: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = UIColor.white.withAlphaComponent(0.94)
        button.setImage(icon(name, pointSize: 13), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.accessibilityLabel = label
        return button
    }

    private static func icon(_ name: String, pointSize: CGFloat) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: config)
    }
}
