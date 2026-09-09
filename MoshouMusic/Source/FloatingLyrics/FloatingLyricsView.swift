import UIKit

/// 悬浮歌词视图 —— 三行歌词（上一句 / 当前句 / 下一句）
/// - 上下两行半透明，中间行完全不透明
/// - 换句时整体「往上翻一行」，带位移 + 透明度过渡
final class FloatingLyricsView: UIView {

    /// 侧行（上/下）的透明度
    static let sideAlpha: CGFloat = 0.45

    private let container = UIView()
    private let labels: [UILabel] = (0..<3).map { _ in UILabel() }

    /// 中间行字号；侧行自动小一号
    var fontSize: CGFloat {
        didSet { applyStyle() }
    }

    init(frame: CGRect, fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        self.fontSize = 16
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 14
        layer.masksToBounds = true

        container.clipsToBounds = true
        container.backgroundColor = .clear
        addSubview(container)

        labels.forEach { label in
            label.textAlignment = .center
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .white
            label.shadowColor = UIColor.black.withAlphaComponent(0.55)
            label.shadowOffset = CGSize(width: 0, height: 1)
            container.addSubview(label)
        }

        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let row = bounds.height / 3
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 10, y: CGFloat(index) * row,
                                 width: max(0, bounds.width - 20), height: row)
        }
    }

    private func applyStyle() {
        for (index, label) in labels.enumerated() {
            let size = index == 1 ? fontSize : max(10, fontSize - 2)
            label.font = UIFont.systemFont(ofSize: size,
                                           weight: index == 1 ? .semibold : .regular)
        }
    }

    // MARK: - 歌词更新

    /// 设置三行文本（上 / 中 / 下）
    /// - Parameter animated: 为 true 时整体向上翻动一行（仅在顺序切到下一句时传 true）
    func setLines(_ lines: [String], animated: Bool) {
        guard lines.count == 3 else { return }

        let applyFinal: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.container.transform = .identity
            for (index, label) in self.labels.enumerated() {
                label.text = lines[index]
                label.alpha = index == 1 ? 1.0 : (lines[index].isEmpty ? 0 : Self.sideAlpha)
            }
        }

        guard animated, window != nil, bounds.height > 0 else {
            UIView.performWithoutAnimation(applyFinal)
            return
        }

        // 先把内容换成新三行，再把容器整体下移一行 —— 视觉上仍停在旧位置
        for (index, label) in labels.enumerated() {
            label.text = lines[index]
        }
        let row = bounds.height / 3
        container.transform = CGAffineTransform(translationX: 0, y: row)
        // 旧「当前行」此刻处于上方一行位置，仍是最亮，随后淡到侧行亮度
        labels[0].alpha = 1.0
        labels[1].alpha = Self.sideAlpha
        labels[2].alpha = 0

        UIView.animate(withDuration: 0.42, delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            self.container.transform = .identity
            self.labels[0].alpha = lines[0].isEmpty ? 0 : Self.sideAlpha
            self.labels[1].alpha = 1.0
            self.labels[2].alpha = lines[2].isEmpty ? 0 : Self.sideAlpha
        }
    }

    /// 无歌词时的占位显示（上：空 / 中：歌名 / 下：歌手）
    func setPlaceholder(name: String, singer: String) {
        setLines(["", name, singer], animated: false)
    }
}

/// 悬浮窗根视图：空白处点击穿透到下层应用
final class FloatingRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
