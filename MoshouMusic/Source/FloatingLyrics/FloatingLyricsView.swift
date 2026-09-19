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

    /// v1.0.175：主题车图装饰层（车型正/侧视图），位于频谱之上、歌词之下
    private var carImageView: UIImageView?
    /// v1.0.175：去重键 —— 仅在主题/车型/朝向/摆放变化时重建车图
    private var appliedThemeKey: String = ""
    /// v1.0.175：当前车图摆放方式（供 layoutSubviews 重定位）
    private var carPlacement: CarPlacement = .none

    /// v1.0.177：GT 渐变背景层（themed 主题专用；纯色主题为 nil，沿用用户纯色）
    private var bgGradientLayer: CAGradientLayer?
    /// v1.0.178：光带两段——深蓝底轨（未播段）+ 星火黄已播填充，组成「进度 = 已播长度」光带
    private var bladeTrack: UIView?
    private var bladeFill: UIView?
    /// v1.0.178：光带填充上的扫光高光（液态金属 / 星火动态）
    private var bladeShimmer: CAGradientLayer?
    /// v1.0.178：当前主题 / 车型 / 歌词布局（驱动动态效果与定位，供 progress 回调使用）
    private var activeTheme: FloatingTheme = .original
    private var activeModel: FloatingCarModel?
    private var lyricsLayout: LyricsLayout = .overlay
    /// v1.0.178：最近一次播放进度（0~1），用于重布局时保持光带已播段
    private var lastProgress: CGFloat = 0

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
        // v1.0.178：左侧分栏主题（侧身/剪影类）歌词只占用左半窗，右侧留给车图；
        // 覆盖式主题歌词跨整窗居中（车图作背景装饰）。
        let lyricsWidth: CGFloat = (lyricsLayout == .leftColumn)
            ? max(0, bounds.width * 0.54) : bounds.width
        container.frame = CGRect(x: 0, y: contentTop,
                                 width: lyricsWidth,
                                 height: max(0, bounds.height - contentTop))
        let row = container.bounds.height / 3
        let labelInset: CGFloat = (lyricsLayout == .leftColumn) ? 14 : 10
        let labelW = max(0, container.bounds.width - labelInset * 2)
        let align: NSTextAlignment = (lyricsLayout == .leftColumn) ? .left : .center
        for (index, label) in labels.enumerated() {
            label.textAlignment = align
            label.frame = CGRect(x: labelInset, y: CGFloat(index) * row,
                                 width: labelW, height: row)
        }
        // v1.0.147：频谱条撑满悬浮窗高度 —— 原来贴底固定 16pt，只占窗口底部一小条，
        // 看不出频谱强弱；现在按「当前悬浮窗设置的高度」铺满（上下各留 3pt 圆角余量）
        spectrumView.frame = CGRect(x: 6, y: 3,
                                    width: max(0, bounds.width - 12),
                                    height: max(0, bounds.height - 6))

        // v1.0.175：车图装饰随窗口尺寸 / 折叠态重定位
        layoutCarImage()

        // v1.0.177：GT 渐变背景层 + 贯穿光带随窗口尺寸重定位
        bgGradientLayer?.frame = bounds
        layoutBlade()
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
        carImageView?.isHidden = collapsed
        bladeTrack?.isHidden = collapsed
        bladeFill?.isHidden = collapsed
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

    // MARK: - 主题 / 车型装饰（v1.0.175）

    /// 应用悬浮窗主题 + 车型：在歌词层之下、频谱之上放置车图装饰，并按主题加强调色描边。
    /// 仅在主题 / 车型 / 朝向 / 摆放变化时重建车图视图，避免布局期重复创建。
    func applyTheme(_ theme: FloatingTheme, model: FloatingCarModel) {
        let collapsed = isCollapsedState
        let key = "\(theme.rawValue)|\(model.id)|\(theme.carOrientation.rawValue)|\(theme.carPlacement.rawValue)"
        if key != appliedThemeKey {
            appliedThemeKey = key
            activeTheme = theme
            activeModel = model
            lyricsLayout = theme.lyricsLayout
            // 先停掉旧主题的动态效果，避免动画在重建后叠加
            stopDynamicEffects()
            // v1.0.177：先铺背景（纯色主题清掉渐变；GT 主题铺 GT 渐变）
            applyBackground(theme)
            carImageView?.removeFromSuperview()
            carImageView = nil
            bladeTrack?.removeFromSuperview(); bladeTrack = nil
            bladeFill?.removeFromSuperview(); bladeFill = nil
            bladeShimmer?.removeFromSuperlayer(); bladeShimmer = nil
            layer.borderWidth = 0
            if theme.usesCarDecoration,
               let img = model.image(orientation: theme.carOrientation) {
                let iv = UIImageView(image: img)
                iv.contentMode = .scaleAspectFit
                iv.clipsToBounds = true
                iv.alpha = theme.carAlpha
                iv.isUserInteractionEnabled = false
                // 插到频谱(索引 0)之上、歌词容器之下 → 车图在文字背后、频谱前方
                insertSubview(iv, at: 1)
                carImageView = iv
                carPlacement = theme.carPlacement
                if theme.accentBorderWidth > 0 {
                    layer.borderColor = theme.accent.cgColor
                    layer.borderWidth = theme.accentBorderWidth
                }
            }
            // v1.0.178：贯穿光带（GT 签名元素；纯色不显示）—— 深蓝底轨 + 星火黄已播段 + 扫光
            applyLightBlade(theme)
            // v1.0.178：启动动态效果（扫光 + 车浮动 / 进度游标）
            startDynamicEffects()
        }
        carImageView?.isHidden = collapsed
        bladeTrack?.isHidden = collapsed
        bladeFill?.isHidden = collapsed
        layoutCarImage()
        layoutBlade()
        refreshHard()
    }

    // MARK: - 背景 / 光带（v1.0.177+）

    /// 纯色主题：移除 GT 渐变层，背景由 manager 设置的用户纯色接管。
    /// GT/新主题：在 self.layer 最底层铺一层自上而下渐变，作为该主题的 GT 底色。
    private func applyBackground(_ theme: FloatingTheme) {
        bgGradientLayer?.removeFromSuperlayer()
        bgGradientLayer = nil
        switch theme.background {
        case .solid:
            // 不动 backgroundColor（manager 已设为用户纯色），仅确保没有残留渐变
            break
        case .gradient(let colors):
            let g = CAGradientLayer()
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
            g.colors = colors.map { $0.cgColor }
            g.frame = bounds
            self.layer.insertSublayer(g, at: 0)
            bgGradientLayer = g
            self.backgroundColor = .clear
        }
    }

    /// 星火黄贯穿光带（v1.0.178 重构为两段式进度光带）：
    /// 底部一条深蓝底轨（未播段），其上叠一条星火黄填充（已播段），
    /// 填充上再跑一道白色扫光高光 —— 既表达「进度 = 已播长度」，又有液态金属/星火的动态观感。
    /// 纯色主题不显示。
    private func applyLightBlade(_ theme: FloatingTheme) {
        guard theme.showsLightBlade else { return }
        let h: CGFloat = 3
        let y = bounds.height - h

        let track = UIView()
        track.isUserInteractionEnabled = false
        track.backgroundColor = UIColor(hex: 0x17375C)
        track.layer.cornerRadius = h / 2
        track.alpha = 0.9
        track.clipsToBounds = true
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        insertSubview(track, at: subviews.count)
        bladeTrack = track

        let fill = UIView()
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = theme.bladeColor
        fill.layer.cornerRadius = h / 2
        fill.alpha = 0.95
        fill.clipsToBounds = true
        fill.frame = CGRect(x: 0, y: y, width: max(0, bounds.width * lastProgress), height: h)
        insertSubview(fill, at: subviews.count)
        bladeFill = fill

        let shim = CAGradientLayer()
        shim.colors = [UIColor.clear.cgColor,
                       UIColor.white.withAlphaComponent(0.55).cgColor,
                       UIColor.clear.cgColor]
        shim.startPoint = CGPoint(x: 0, y: 0.5)
        shim.endPoint = CGPoint(x: 1, y: 0.5)
        shim.locations = [0, 0.5, 1]
        fill.layer.addSublayer(shim)
        shim.frame = fill.bounds
        bladeShimmer = shim
    }

    /// 重定位光带两段（随窗口尺寸 / 进度变化）
    private func layoutBlade() {
        guard let track = bladeTrack, let fill = bladeFill else { return }
        let h: CGFloat = 3
        let y = bounds.height - h
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        fill.frame = CGRect(x: 0, y: y, width: max(0, bounds.width * lastProgress), height: h)
        bladeShimmer?.frame = fill.bounds
    }

    /// v1.0.178：启动主题动态效果
    private func startDynamicEffects() {
        guard activeTheme != .original else { return }
        // 星火黄扫光：沿光带已播段做横向往复扫光
        if let fill = bladeFill, let shim = bladeShimmer {
            let w = max(40, bounds.width)
            shim.frame = fill.bounds
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = -w
            anim.toValue = w
            anim.duration = 1.8
            anim.repeatCount = .greatestFiniteMagnitude
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shim.add(anim, forKey: "bladeShimmer")
        }
        // 车图轻微浮动（仅非「进度游标」主题，避免与 x 进度绑定冲突）
        if let iv = carImageView, activeTheme.carFollowsProgress == false {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = -2.0
            bob.toValue = 2.0
            bob.duration = 2.4
            bob.autoreverses = true
            bob.repeatCount = .greatestFiniteMagnitude
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            iv.layer.add(bob, forKey: "carBob")
        }
    }

    /// 停止所有主题动态效果（切主题重建前调用）
    private func stopDynamicEffects() {
        bladeShimmer?.removeAnimation(forKey: "bladeShimmer")
        carImageView?.layer.removeAnimation(forKey: "carBob")
    }

    /// v1.0.178：播放进度回调（由 manager 在 spectrumTick 中转发）。
    /// 更新光带已播段宽度；若主题为「行驶进度」（车=进度游标），同步移动车图 x 位置。
    func updateProgress(current: Double, duration: Double) {
        let p = (duration > 0 && current.isFinite) ? min(1, max(0, current / duration)) : 0
        lastProgress = CGFloat(p)
        guard let fill = bladeFill else { return }
        let h: CGFloat = 3
        let y = bounds.height - h
        fill.frame = CGRect(x: 0, y: y, width: max(0, bounds.width * CGFloat(p)), height: h)
        bladeShimmer?.frame = fill.bounds
        if activeTheme.carFollowsProgress, let iv = carImageView {
            let margin: CGFloat = 20
            let x = margin + CGFloat(p) * max(0, bounds.width - margin * 2)
            iv.center = CGPoint(x: x, y: bounds.height - 22)
        }
    }

    /// 按当前摆放方式计算车图 frame
    private func layoutCarImage() {
        guard let iv = carImageView else { return }
        iv.frame = Self.carFrame(for: carPlacement, in: bounds)
    }

    private static func carFrame(for placement: CarPlacement, in rect: CGRect) -> CGRect {
        switch placement {
        case .none:
            return .zero
        case .backdrop:
            return rect.insetBy(dx: 4, dy: 4)
        case .bottom:
            return CGRect(x: 4, y: rect.height * 0.30,
                          width: rect.width - 8, height: rect.height * 0.70)
        case .right:
            // 侧身剪影：占右半窗、近乎铺满高度，呼应设计稿「车在右、歌词在左」
            return CGRect(x: rect.width * 0.40, y: 6,
                          width: rect.width * 0.60 - 6, height: rect.height - 12)
        case .card:
            return CGRect(x: 4, y: 4,
                          width: rect.width - 8, height: rect.height * 0.6)
        case .cursor:
            // 行驶进度：车=游标，初始落在底部光带左侧，x 由 updateProgress 驱动
            let h = min(42, rect.height * 0.42)
            let w = h * 1.9
            return CGRect(x: 20 - w / 2, y: rect.height - h - 6, width: w, height: h)
        }
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
