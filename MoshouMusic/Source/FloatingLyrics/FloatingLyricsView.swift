import UIKit

/// 悬浮歌词视图 —— 三行歌词（上一句 / 当前句 / 下一句）
/// - 上下两行半透明，中间行完全不透明
/// - 换句时整体「往上翻一行」，带位移 + 透明度过渡
///
/// v1.0.181：四种新版主题（newA/newB/newC/newD）为独立卡片布局，按设计稿实现，
/// 不再在旧三行歌词悬浮窗上叠加元素。original 仍走经典布局。
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

    /// 主题车图装饰层（车型正/侧视图）
    private var carImageView: UIImageView?
    /// 右上角小号车头徽标（极简主题）
    private var badgeImageView: UIImageView?
    /// 去重键 —— 仅在主题/车型/朝向/摆放变化时重建车图
    private var appliedThemeKey: String = ""
    /// 当前车图摆放方式（供 layoutSubviews 重定位）
    private var carPlacement: CarPlacement = .none

    /// 渐变背景层（非纯色主题专用；新版主题为纯深色，不用渐变）
    private var bgGradientLayer: CAGradientLayer?
    /// 进度条：深色底轨 + 黄→青蓝渐变已播填充 + 白色扫光
    private var bladeTrack: UIView?
    private var bladeFill: UIView?
    private var bladeFillGradient: CAGradientLayer?
    private var bladeShimmer: CAGradientLayer?
    /// 当前主题 / 车型 / 歌词布局
    private var activeTheme: FloatingTheme = .original
    private var activeModel: FloatingCarModel?
    private var lyricsLayout: LyricsLayout = .overlay
    /// 最近一次播放进度（0~1），用于重布局时保持进度条已播段
    private var lastProgress: CGFloat = 0
    /// A/C 布局的封面 + 歌名歌手信息缓存
    private var lastCover: UIImage?
    private var lastTitle: String = ""
    private var lastArtist: String = ""
    /// A 窄条左侧封面
    private var coverImageView: UIImageView?
    /// 歌名 / 歌手标签
    private var titleLabel: UILabel?
    private var artistLabel: UILabel?
    /// A 窄条左右时间
    private var timeLeftLabel: UILabel?
    private var timeRightLabel: UILabel?

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
        layer.cornerRadius = 16
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

        spectrumView.isHidden = true
        spectrumView.alpha = 0.42
        addSubview(spectrumView)
        sendSubviewToBack(spectrumView)

        addSubview(controlBar)

        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = controlBar.isHidden ? 0 : controlBarHeight()
        let barWidth = controlBar.isHidden ? 0 : min(max(0, bounds.width - 8), max(0, barHeight * 3.9))
        if !controlBar.isHidden {
            controlBar.frame = CGRect(x: (bounds.width - barWidth) / 2, y: 3,
                                      width: barWidth, height: barHeight)
        }
        let contentTop = controlBar.isHidden ? 0 : min(bounds.height, controlBar.frame.maxY + 2)

        switch activeTheme {
        case .newA:
            layoutNarrowBar(contentTop: contentTop)
        case .newB:
            layoutBigCard(contentTop: contentTop)
        case .newC:
            layoutFrontWindow(contentTop: contentTop)
        case .newD:
            layoutMinimal(contentTop: contentTop)
        default:
            layoutClassic(contentTop: contentTop)
        }

        spectrumView.frame = CGRect(x: 6, y: 3,
                                    width: max(0, bounds.width - 12),
                                    height: max(0, bounds.height - 6))

        layoutCarImage()
        layoutBadge()
        bgGradientLayer?.frame = bounds
        layoutBlade()
    }

    // MARK: - v1.0.181 四种新版布局

    /// A 窄条：左侧圆形封面 + 右侧歌名歌手，底部进度条（车侧影作游标），左右时间
    private func layoutNarrowBar(contentTop: CGFloat) {
        container.isHidden = true
        coverImageView?.isHidden = false
        titleLabel?.isHidden = false
        artistLabel?.isHidden = false
        timeLeftLabel?.isHidden = false
        timeRightLabel?.isHidden = false

        let inset: CGFloat = 12
        let bottomPad: CGFloat = 18
        let coverSize: CGFloat = min(46, max(34, bounds.height - contentTop - bottomPad - 8))
        let coverX: CGFloat = inset
        let coverY = contentTop + (bounds.height - contentTop - coverSize - bottomPad) / 2
        coverImageView?.frame = CGRect(x: coverX, y: coverY, width: coverSize, height: coverSize)

        let textX = coverX + coverSize + 10
        let textW = max(0, bounds.width - textX - inset - (badgeImageView != nil ? 38 : 0))
        let titleH: CGFloat = 19
        let artistH: CGFloat = 14
        let textY = coverY + (coverSize - titleH - artistH - 2) / 2
        titleLabel?.frame = CGRect(x: textX, y: textY, width: textW, height: titleH)
        artistLabel?.frame = CGRect(x: textX, y: textY + titleH + 2, width: textW, height: artistH)

        let timeY = bounds.height - 14
        timeLeftLabel?.frame = CGRect(x: inset, y: timeY, width: 46, height: 12)
        timeRightLabel?.frame = CGRect(x: bounds.width - inset - 46, y: timeY, width: 46, height: 12)
    }

    /// B 大卡：左上三行歌词 + 车左侧空白歌名歌手 + 右下大车 + 底部粗进度条
    private func layoutBigCard(contentTop: CGFloat) {
        container.isHidden = false
        titleLabel?.isHidden = false
        artistLabel?.isHidden = false
        coverImageView?.isHidden = true
        timeLeftLabel?.isHidden = true
        timeRightLabel?.isHidden = true

        let inset: CGFloat = 16
        let progressH: CGFloat = 16
        let progressPad: CGFloat = 20
        let lyricsTop: CGFloat = contentTop + 14
        let lyricsH: CGFloat = min(bounds.height - lyricsTop - 92, 96)
        container.frame = CGRect(x: inset, y: lyricsTop, width: bounds.width - inset * 2, height: max(0, lyricsH))
        let row = container.bounds.height / 3
        let labelW = max(0, container.bounds.width)
        for (index, label) in labels.enumerated() {
            label.textAlignment = .left
            label.frame = CGRect(x: 0, y: CGFloat(index) * row, width: labelW, height: row)
        }

        let infoY = lyricsTop + max(0, lyricsH) + 8
        titleLabel?.frame = CGRect(x: inset, y: infoY, width: bounds.width - inset * 2, height: 20)
        artistLabel?.frame = CGRect(x: inset, y: infoY + 22, width: bounds.width - inset * 2, height: 16)
    }

    /// C 车头窗：左侧车头正视大图，右侧歌名歌手 + 歌词 + 进度条
    private func layoutFrontWindow(contentTop: CGFloat) {
        container.isHidden = false
        titleLabel?.isHidden = false
        artistLabel?.isHidden = false
        coverImageView?.isHidden = true
        timeLeftLabel?.isHidden = true
        timeRightLabel?.isHidden = true

        let leftW = bounds.width * 0.70
        let rightX = leftW + 2
        let rightW = max(0, bounds.width - rightX - 12)
        let topY = contentTop + 12
        titleLabel?.frame = CGRect(x: rightX, y: topY, width: rightW, height: 18)
        artistLabel?.frame = CGRect(x: rightX, y: topY + 20, width: rightW, height: 14)

        let bladeReserved: CGFloat = 16
        let lyricsY = topY + 44
        let lyricsH = max(0, bounds.height - lyricsY - bladeReserved)
        container.frame = CGRect(x: rightX, y: lyricsY, width: rightW, height: lyricsH)
        let row = container.bounds.height / 3
        let labelW = max(0, rightW)
        for (index, label) in labels.enumerated() {
            label.textAlignment = .left
            label.frame = CGRect(x: 0, y: CGFloat(index) * row, width: labelW, height: row)
        }
    }

    /// D 极简：纯底部进度条（车侧影作游标）+ 右侧车头徽标
    private func layoutMinimal(contentTop: CGFloat) {
        container.isHidden = true
        coverImageView?.isHidden = true
        titleLabel?.isHidden = true
        artistLabel?.isHidden = true
        timeLeftLabel?.isHidden = true
        timeRightLabel?.isHidden = true
    }

    /// 经典布局（original）：保留原有三种 lyricsLayout 行为
    private func layoutClassic(contentTop: CGFloat) {
        container.isHidden = false
        coverImageView?.isHidden = true
        titleLabel?.isHidden = true
        artistLabel?.isHidden = true
        timeLeftLabel?.isHidden = true
        timeRightLabel?.isHidden = true

        var lyricsX: CGFloat = 0
        var lyricsWidth: CGFloat = bounds.width
        var align: NSTextAlignment = .center
        var labelInset: CGFloat = 10
        switch lyricsLayout {
        case .overlay:
            lyricsX = 0; lyricsWidth = bounds.width; align = .center; labelInset = 10
        case .leftColumn:
            lyricsX = 0; lyricsWidth = bounds.width * 0.54; align = .left; labelInset = 14
        case .rightColumn:
            lyricsX = bounds.width * 0.46; lyricsWidth = bounds.width * 0.54; align = .left; labelInset = 14
        }
        let bottomInset = min(activeTheme.lyricsBottomInset,
                              max(0, bounds.height - contentTop - 24))
        container.frame = CGRect(x: lyricsX, y: contentTop,
                                 width: lyricsWidth,
                                 height: max(0, bounds.height - contentTop - bottomInset))
        let row = container.bounds.height / 3
        let labelW = max(0, container.bounds.width - labelInset * 2)
        for (index, label) in labels.enumerated() {
            label.textAlignment = align
            label.frame = CGRect(x: labelInset, y: CGFloat(index) * row,
                                 width: labelW, height: row)
        }
    }

    /// 控制条高度随悬浮窗尺寸缩放 —— 22~32pt
    private func controlBarHeight() -> CGFloat {
        return min(32, max(22, bounds.height * 0.26))
    }

    private func applyStyle() {
        for (index, label) in labels.enumerated() {
            var size = index == 1 ? fontSize : max(9, fontSize * 0.7)
            if activeTheme == .newB {
                size = index == 1 ? fontSize * 1.25 : (index == 0 ? fontSize * 0.85 : fontSize * 0.85)
                label.textColor = index == 1 ? UIColor(hex: 0xE5FF00) : .white
            } else if activeTheme.isNewTheme {
                label.textColor = index == 1 ? .white : UIColor.white.withAlphaComponent(0.6)
            } else {
                label.textColor = .white
            }
            label.font = UIFont.systemFont(ofSize: size,
                                           weight: index == 1 ? .semibold : .regular)
        }
        refreshHard()
    }

    /// 强制全部 label 全量重绘
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

        for (index, label) in labels.enumerated() {
            label.text = lines[index]
        }
        let row = bounds.height / 3
        container.transform = CGAffineTransform(translationX: 0, y: row)
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
        badgeImageView?.isHidden = collapsed
        bladeTrack?.isHidden = collapsed
        bladeFill?.isHidden = collapsed
        container.isHidden = collapsed
        coverImageView?.isHidden = collapsed
        titleLabel?.isHidden = collapsed
        artistLabel?.isHidden = collapsed
        timeLeftLabel?.isHidden = collapsed
        timeRightLabel?.isHidden = collapsed
        spectrumView.isHidden = collapsed || !spectrumEnabled
        controlBar.isHidden = collapsed || activeTheme.isNewTheme
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
            artworkIcon?.image = lastArtwork
            noteIcon?.isHidden = (lastArtwork != nil)
            artworkIcon?.isHidden = (lastArtwork == nil)
        } else {
            noteIcon?.isHidden = true
            artworkIcon?.isHidden = true
            refreshHard()
        }
    }

    /// 折叠圆点显示歌曲封面（无封面回退音符）
    func setArtwork(_ image: UIImage?) {
        lastArtwork = image
        artworkIcon?.image = image
        coverImageView?.image = image
        lastCover = image
        if isCollapsedState {
            noteIcon?.isHidden = (image != nil)
            artworkIcon?.isHidden = (image == nil)
        }
    }

    /// 设置 A/C/B 布局所需的封面 + 歌名歌手信息
    func setNowPlayingInfo(cover: UIImage?, title: String, artist: String) {
        lastCover = cover
        lastTitle = title
        lastArtist = artist
        coverImageView?.image = cover
        titleLabel?.text = title
        artistLabel?.text = artist
        refreshHard()
    }

    /// 频谱条可见性（音乐可视化开关）
    func setSpectrumVisible(_ visible: Bool) {
        spectrumEnabled = visible
        spectrumView.isHidden = !visible || isCollapsedState
    }

    // MARK: - 主题 / 车型装饰

    /// 应用悬浮窗主题 + 车型，按主题重建车图 / 信息视图 / 进度条
    func applyTheme(_ theme: FloatingTheme, model: FloatingCarModel) {
        let collapsed = isCollapsedState
        let key = "\(theme.rawValue)|\(model.id)|\(theme.carOrientation.rawValue)|\(theme.carPlacement.rawValue)"
        if key != appliedThemeKey {
            appliedThemeKey = key
            activeTheme = theme
            activeModel = model
            lyricsLayout = theme.lyricsLayout
            stopDynamicEffects()
            applyBackground(theme)
            carImageView?.removeFromSuperview(); carImageView = nil
            badgeImageView?.removeFromSuperview(); badgeImageView = nil
            bladeTrack?.removeFromSuperview(); bladeTrack = nil
            bladeFill?.removeFromSuperview(); bladeFill = nil
            bladeFillGradient?.removeFromSuperlayer(); bladeFillGradient = nil
            bladeShimmer?.removeFromSuperlayer(); bladeShimmer = nil
            coverImageView?.removeFromSuperview(); coverImageView = nil
            titleLabel?.removeFromSuperview(); titleLabel = nil
            artistLabel?.removeFromSuperview(); artistLabel = nil
            timeLeftLabel?.removeFromSuperview(); timeLeftLabel = nil
            timeRightLabel?.removeFromSuperview(); timeRightLabel = nil
            layer.borderWidth = 0

            if theme.usesCarDecoration,
               let img = carImage(for: theme, model: model) {
                let iv = UIImageView(image: img)
                iv.contentMode = .scaleAspectFit
                iv.clipsToBounds = true
                iv.alpha = theme.carAlpha
                iv.isUserInteractionEnabled = false
                insertSubview(iv, at: 1)
                carImageView = iv
                carPlacement = theme.carPlacement
                let bw = ConfigStore.shared.floatingBorderWidth > 0 ? ConfigStore.shared.floatingBorderWidth : theme.accentBorderWidth
                if bw > 0 {
                    let bc: UIColor = (ConfigStore.shared.floatingBorderColorHex != 0)
                        ? UIColor(hex: ConfigStore.shared.floatingBorderColorHex)
                        : theme.borderColor
                    layer.borderColor = bc.cgColor
                    layer.borderWidth = bw
                }
            }
            if theme == .newA {
                makeCoverView(); makeTitleLabel(); makeArtistLabel(); makeTimeLabels()
                styleInfoLabels(theme: theme)
            } else if theme == .newB {
                makeTitleLabel(); makeArtistLabel()
                styleInfoLabels(theme: theme)
            } else if theme == .newC {
                makeTitleLabel(); makeArtistLabel()
                styleInfoLabels(theme: theme)
            }
            applyBadge(theme, model)
            applyLightBlade(theme)
            startDynamicEffects()
            // 回填缓存的封面/歌名歌手
            coverImageView?.image = lastCover
            titleLabel?.text = lastTitle
            artistLabel?.text = lastArtist
        }
        controlBar.isHidden = collapsed || theme.isNewTheme
        carImageView?.isHidden = collapsed
        bladeTrack?.isHidden = collapsed
        bladeFill?.isHidden = collapsed
        applyStyle()
        layoutCarImage()
        layoutBlade()
        applyCarCursor()
        refreshHard()
    }

    private func styleInfoLabels(theme: FloatingTheme) {
        switch theme {
        case .newA, .newC:
            titleLabel?.textColor = .white
            titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            artistLabel?.textColor = UIColor.white.withAlphaComponent(0.7)
            artistLabel?.font = UIFont.systemFont(ofSize: 12, weight: .regular)
            titleLabel?.textAlignment = .left
            artistLabel?.textAlignment = .left
        case .newB:
            titleLabel?.textColor = UIColor(hex: 0x00E5FF)
            titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            artistLabel?.textColor = UIColor(hex: 0x00E5FF).withAlphaComponent(0.85)
            artistLabel?.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            titleLabel?.textAlignment = .left
            artistLabel?.textAlignment = .left
        default:
            break
        }
    }

    // MARK: - 信息视图构造

    private func makeCoverView() {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 23
        iv.layer.borderWidth = 0.5
        iv.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        iv.isUserInteractionEnabled = false
        insertSubview(iv, at: subviews.count)
        coverImageView = iv
    }

    private func makeTitleLabel() {
        let l = UILabel()
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        l.textAlignment = .left
        l.lineBreakMode = .byTruncatingTail
        l.shadowColor = UIColor.black.withAlphaComponent(0.55)
        l.shadowOffset = CGSize(width: 0, height: 1)
        insertSubview(l, at: subviews.count)
        titleLabel = l
    }

    private func makeArtistLabel() {
        let l = UILabel()
        l.textColor = UIColor.white.withAlphaComponent(0.7)
        l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        l.textAlignment = .left
        l.lineBreakMode = .byTruncatingTail
        insertSubview(l, at: subviews.count)
        artistLabel = l
    }

    private func makeTimeLabels() {
        let fmt: (UILabel) -> Void = { l in
            l.textColor = UIColor.white.withAlphaComponent(0.6)
            l.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textAlignment = .left
        }
        let left = UILabel(); fmt(left); left.text = "00:00"
        let right = UILabel(); fmt(right); right.text = "00:00"; right.textAlignment = .right
        insertSubview(left, at: subviews.count)
        insertSubview(right, at: subviews.count)
        timeLeftLabel = left
        timeRightLabel = right
    }

    // MARK: - 车图 / 徽标辅助

    private func carImage(for theme: FloatingTheme, model: FloatingCarModel) -> UIImage? {
        guard let img = model.image(orientation: theme.carOrientation) else { return nil }
        if theme.carFacesRight && theme.carOrientation == .side,
           let cg = img.cgImage {
            return UIImage(cgImage: cg, scale: img.scale, orientation: .upMirrored)
        }
        return img
    }

    /// 右上角小号车头徽标（极简主题）
    private func applyBadge(_ theme: FloatingTheme, _ model: FloatingCarModel) {
        badgeImageView?.removeFromSuperview()
        badgeImageView = nil
        guard theme.badgeFront,
              let fimg = model.image(orientation: .front) else { return }
        let b = UIImageView(image: fimg)
        b.contentMode = .scaleAspectFit
        b.clipsToBounds = true
        b.layer.cornerRadius = 6
        b.isUserInteractionEnabled = false
        insertSubview(b, at: subviews.count)
        badgeImageView = b
    }

    private func layoutBadge() {
        guard let b = badgeImageView else { return }
        let s: CGFloat = 30
        b.frame = CGRect(x: bounds.width - s - 8, y: 6, width: s, height: s)
    }

    // MARK: - 背景

    /// 新版主题：纯深色背景（设计稿深色卡片）；original：沿用用户纯色
    private func applyBackground(_ theme: FloatingTheme) {
        bgGradientLayer?.removeFromSuperlayer()
        bgGradientLayer = nil
        if let solid = theme.solidBackgroundColor {
            self.backgroundColor = solid
            return
        }
        switch theme.background {
        case .solid:
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

    /// 圆角进度条 —— 深色底轨 + 黄→青蓝渐变已播填充 + 白色扫光
    private func applyLightBlade(_ theme: FloatingTheme) {
        guard theme.showsLightBlade else { return }
        let h: CGFloat = (theme == .newB) ? 16 : 6
        let inset: CGFloat = (theme == .newA || theme == .newD) ? 12 : 16
        let bottomPad: CGFloat = (theme == .newA) ? 18 : ((theme == .newB) ? 20 : 16)
        let y = bounds.height - h - bottomPad
        let w = max(0, bounds.width - inset * 2)

        let track = UIView()
        track.isUserInteractionEnabled = false
        track.backgroundColor = theme.progressTrackColor
        track.layer.cornerRadius = h / 2
        track.alpha = 0.9
        track.clipsToBounds = true
        track.frame = CGRect(x: inset, y: y, width: w, height: h)
        insertSubview(track, at: subviews.count)
        bladeTrack = track

        let fill = UIView()
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = .clear
        fill.layer.cornerRadius = h / 2
        fill.clipsToBounds = true
        fill.frame = CGRect(x: inset, y: y, width: max(0, w * lastProgress), height: h)
        insertSubview(fill, at: subviews.count)
        bladeFill = fill

        let grad = CAGradientLayer()
        grad.startPoint = CGPoint(x: 0, y: 0.5)
        grad.endPoint = CGPoint(x: 1, y: 0.5)
        grad.colors = theme.progressGradient.map { $0.cgColor }
        fill.layer.addSublayer(grad)
        grad.frame = fill.bounds
        bladeFillGradient = grad

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

    /// 重定位进度条（随窗口尺寸 / 进度变化）
    private func layoutBlade() {
        guard let track = bladeTrack, let fill = bladeFill else { return }
        let inset = track.frame.origin.x
        let h: CGFloat = (activeTheme == .newB) ? 16 : 6
        let bottomPad: CGFloat = (activeTheme == .newA) ? 18 : ((activeTheme == .newB) ? 20 : 16)
        let y = bounds.height - h - bottomPad
        let w = max(0, bounds.width - inset * 2)
        track.frame = CGRect(x: inset, y: y, width: w, height: h)
        fill.frame = CGRect(x: inset, y: y, width: max(0, w * lastProgress), height: h)
        bladeFillGradient?.frame = fill.bounds
        bladeShimmer?.frame = fill.bounds
    }

    /// 启动主题动态效果
    private func startDynamicEffects() {
        guard activeTheme != .original else { return }
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

    private func stopDynamicEffects() {
        bladeShimmer?.removeAnimation(forKey: "bladeShimmer")
        carImageView?.layer.removeAnimation(forKey: "carBob")
    }

    /// 播放进度回调：更新渐变已播段；游标类主题同步移动车图
    func updateProgress(current: Double, duration: Double) {
        let p = (duration > 0 && current.isFinite) ? min(1, max(0, current / duration)) : 0
        lastProgress = CGFloat(p)
        guard let fill = bladeFill, let track = bladeTrack else { return }
        let inset = track.frame.origin.x
        let h: CGFloat = (activeTheme == .newB) ? 16 : 6
        let bottomPad: CGFloat = (activeTheme == .newA) ? 18 : ((activeTheme == .newB) ? 20 : 16)
        let y = bounds.height - h - bottomPad
        let w = max(0, bounds.width - inset * 2)
        fill.frame = CGRect(x: inset, y: y, width: max(0, w * CGFloat(p)), height: h)
        bladeFillGradient?.frame = fill.bounds
        bladeShimmer?.frame = fill.bounds
        applyCarCursor()
        timeLeftLabel?.text = formatTime(current)
        timeRightLabel?.text = formatTime(duration)
    }

    private func applyCarCursor() {
        guard activeTheme.carFollowsProgress, let iv = carImageView, let track = bladeTrack else { return }
        let inset = track.frame.origin.x
        let w = max(0, bounds.width - inset * 2)
        let margin: CGFloat = 22
        let x = inset + margin + lastProgress * max(0, w - margin * 2)
        iv.center = CGPoint(x: x, y: track.frame.midY)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 按当前摆放方式计算车图 frame
    private func layoutCarImage() {
        guard let iv = carImageView else { return }
        if activeTheme.carFollowsProgress, let track = bladeTrack {
            // 先定尺寸（避免沿用原图大尺寸），再按进度定位，保证每次布局后车都跟随播放进度
            iv.frame = Self.carFrame(for: carPlacement, in: bounds)
            applyCarCursor()
            return
        }
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
            return CGRect(x: rect.width * 0.40, y: 6,
                          width: rect.width * 0.60 - 6, height: rect.height - 12)
        case .card:
            return CGRect(x: 4, y: 4,
                          width: rect.width - 8, height: rect.height * 0.6)
        case .rightLarge:
            return CGRect(x: rect.width * 0.34, y: 6,
                          width: rect.width * 0.66 - 6, height: rect.height - 12)
        case .frontLeft:
            // 车头窗：车头正视图放大 ~50%，贴近右侧歌词
            let w = rect.width * 0.74
            let h = rect.height * 1.12
            return CGRect(x: -rect.width * 0.03, y: (rect.height - h) / 2, width: w, height: h)
        case .cursorBottom:
            // 窄条/极简：车侧影作游标，缩小到能完整显示全貌
            let h = min(26, rect.height * 0.42)
            let w = h * 2.2
            return CGRect(x: 20 - w / 2, y: rect.height - h - 14, width: w, height: h)
        case .bottomRight:
            // 大卡：车大图占右下，顶部留歌词、底部留粗进度条
            let h = rect.height * 0.52
            let w = min(rect.width * 0.66, h * 2.1)
            return CGRect(x: rect.width - w - 8, y: rect.height - h - 34, width: w, height: h)
        case .bottomLarge:
            // 旧大卡（兼容保留）：车大图占中下部，歌词在顶部
            let h = rect.height * 0.60
            let w = min(rect.width * 0.72, h * 2.0)
            return CGRect(x: (rect.width - w) / 2, y: rect.height - h - 30, width: w, height: h)
        }
    }
}

/// 十段频谱条（随音乐节奏跳动）
final class SpectrumBarsView: UIView {

    var levels: [Float] = Array(repeating: 0, count: 10) {
        didSet { setNeedsDisplay() }
    }
    var barColor: UIColor = UIColor.white.withAlphaComponent(0.6)
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
