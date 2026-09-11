import UIKit

/// 悬浮歌词视图 —— 三行歌词（上一句 / 当前句 / 下一句）
/// - 上下两行半透明，中间行完全不透明
/// - 换句时整体「往上翻一行」，带位移 + 透明度过渡
final class FloatingLyricsView: UIView {

    /// 侧行（上/下）的透明度
    static let sideAlpha: CGFloat = 0.45

    private let container = UIView()
    private let labels: [UILabel] = (0..<3).map { _ in UILabel() }
    private var noteIcon: UIImageView?
    private var artworkIcon: UIImageView?
    /// 折叠态（视图自身状态，供 setArtwork 判断圆点显隐）
    private(set) var isCollapsedState = false
    /// v1.0.144：封面缓存 lastArtwork —— artworkIcon 折叠时才惰性创建，创建前先存
    private var lastArtwork: UIImage?
    /// v1.0.141：底部频谱条（音乐可视化，开关控制可见）
    let spectrumView = SpectrumBarsView()
    /// v1.0.154：顶部半透明播放控制条（上一首 / 播放暂停 / 下一首）
    let controlBar = FloatingControlBar()
    /// v1.0.147：频谱开关状态（折叠态要联动隐藏）
    private var spectrumEnabled = false

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

        // v1.0.141：频谱条垫在歌词层下面
        spectrumView.isHidden = true
        // v1.0.147：撑满窗口后面积大得多，降透明度避免压过歌词可读性
        spectrumView.alpha = 0.42
        addSubview(spectrumView)
        sendSubviewToBack(spectrumView)

        // v1.0.154：控制条浮在最上层（半透明胶囊；频谱/歌词都在它下面）
        addSubview(controlBar)

        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // v1.0.154：顶部控制条先定尺寸；歌词容器整体下移让出它的高度（不遮歌词行）
        let barHeight = controlBarHeight()
        let barWidth = min(max(0, bounds.width - 8), max(0, barHeight * 3.9))
        controlBar.frame = CGRect(x: (bounds.width - barWidth) / 2, y: 3,
                                  width: barWidth, height: barHeight)

        let contentTop = controlBar.isHidden ? 0 : min(bounds.height, controlBar.frame.maxY + 2)
        container.frame = CGRect(x: 0, y: contentTop,
                                 width: bounds.width,
                                 height: max(0, bounds.height - contentTop))
        let row = container.bounds.height / 3
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 10, y: CGFloat(index) * row,
                                 width: max(0, bounds.width - 20), height: row)
        }
        // v1.0.147：频谱条撑满悬浮窗高度 —— 原来贴底固定 16pt，只占窗口底部一小条，
        // 看不出频谱强弱；现在按「当前悬浮窗设置的高度」铺满（上下各留 3pt 圆角余量）
        spectrumView.frame = CGRect(x: 6, y: 3,
                                    width: max(0, bounds.width - 12),
                                    height: max(0, bounds.height - 6))
    }

    /// v1.0.154：控制条高度随悬浮窗尺寸缩放 —— 22~32pt，保证最小窗（72pt）也留得住歌词
    private func controlBarHeight() -> CGFloat {
        return min(32, max(22, bounds.height * 0.26))
    }

    private func applyStyle() {
        for (index, label) in labels.enumerated() {
            // v1.0.116：上下两行 = 中间行的 70%（原来是固定小 2pt）
            let size = index == 1 ? fontSize : max(9, fontSize * 0.7)
            label.font = UIFont.systemFont(ofSize: size,
                                           weight: index == 1 ? .semibold : .regular)
        }
        refreshHard()
    }

    /// 强制全部 label 全量重绘（配合 manager.forceRecomposite 消除注册窗口的渲染残影）
    func refreshHard() {
        setNeedsLayout()
        layoutIfNeeded()
        labels.forEach {
            $0.setNeedsDisplay()
            $0.layer.setNeedsDisplay()
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

    /// 折叠态：隐藏歌词，显示封面图（无封面时回退音符图标）
    func setCollapsed(_ collapsed: Bool) {
        isCollapsedState = collapsed
        container.isHidden = collapsed
        // v1.0.147：折叠成正方形圆点时频谱条不显示（否则会压住封面）
        spectrumView.isHidden = collapsed || !spectrumEnabled
        // v1.0.154：折叠圆点（48×48）放不下控制条，一并隐藏；展开时 layoutSubviews 会复位
        controlBar.isHidden = collapsed
        if collapsed {
            if noteIcon == nil {
                let icon = UIImageView(image: UIImage(systemName: "music.note"))
                icon.tintColor = .white
                icon.contentMode = .center
                addSubview(icon)
                icon.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 26),
                    icon.heightAnchor.constraint(equalToConstant: 26),
                ])
                noteIcon = icon
            }
            if artworkIcon == nil {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 13
                iv.layer.borderWidth = 1
                iv.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
                addSubview(iv)
                iv.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    iv.centerXAnchor.constraint(equalTo: centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 40),
                    iv.heightAnchor.constraint(equalToConstant: 40),
                ])
                artworkIcon = iv
            }
            // v1.0.144：封面缓存回填（icon 是折叠时才创建，show() 时的 setArtwork 早于创建）
            artworkIcon?.image = lastArtwork
            noteIcon?.isHidden = (lastArtwork != nil)
            artworkIcon?.isHidden = (lastArtwork == nil)
        } else {
            noteIcon?.isHidden = true
            artworkIcon?.isHidden = true
            refreshHard()
        }
    }

    /// v1.0.141：折叠圆点显示歌曲封面（无封面回退音符）
    func setArtwork(_ image: UIImage?) {
        lastArtwork = image
        artworkIcon?.image = image
        if isCollapsedState {
            noteIcon?.isHidden = (image != nil)
            artworkIcon?.isHidden = (image == nil)
        }
    }

    /// v1.0.141：频谱条可见性（音乐可视化开关）
    /// v1.0.147：记住开关状态，并与折叠态联动（折叠时不显示）
    func setSpectrumVisible(_ visible: Bool) {
        spectrumEnabled = visible
        spectrumView.isHidden = !visible || isCollapsedState
    }
}

/// v1.0.141：十段频谱条（随音乐节奏跳动）
final class SpectrumBarsView: UIView {

    var levels: [Float] = Array(repeating: 0, count: 10) {
        didSet { setNeedsDisplay() }
    }
    var barColor: UIColor = UIColor.white.withAlphaComponent(0.6)
    /// v1.0.148：频谱最高高度占比 —— 100% 会顶满窗口太满，默认 75% 留出顶部余量
    var heightScale: CGFloat = 0.75

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let n = levels.count
        guard n > 0, bounds.width > 0 else { return }
        let gap: CGFloat = 2.5
        let bw = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        ctx.setFillColor(barColor.cgColor)
        for i in 0..<n {
            let h = max(1.5, CGFloat(levels[i]) * bounds.height * heightScale)
            let r = CGRect(x: CGFloat(i) * (bw + gap), y: bounds.height - h, width: bw, height: h)
            let path = UIBezierPath(roundedRect: r, cornerRadius: min(2.5, bw / 2))
            path.fill()
        }
    }
}
