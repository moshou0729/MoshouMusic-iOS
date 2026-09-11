import UIKit

/// v1.0.141：十段均衡器设置页 —— 10 根竖向滑杆 + 预设方案，实时生效。
final class EqualizerViewController: UIViewController {

    private let enableSwitch = UISwitch()
    private let presetScroll = UIScrollView()
    private let presetStack = UIStackView()
    private let gainStack = UIStackView()
    private var sliders: [GainSlider] = []
    private var valueLabels: [UILabel] = []
    private var presetButtons: [UIButton] = []
    private let tipLabel = UILabel()

    private static let presets: [(name: String, gains: [Float])] = [
        ("标准", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("流行", [-1, 1, 3, 4, 3, 1, -1, -1, -1, -1]),
        ("摇滚", [4, 3, 2, 0, -1, 0, 2, 3, 4, 4]),
        ("古典", [3, 2, 1, 0, 0, 0, -1, -1, 0, 2]),
        ("爵士", [2, 2, 1, 1, -1, -1, 0, 1, 2, 3]),
        ("电子", [4, 3, 1, 0, -2, 1, 1, 3, 4, 4]),
        ("低音增强", [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("人声", [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "均衡器"
        view.backgroundColor = Theme.bg
        setupUI()
        selectPreset(matchingCurrent: true)
    }

    // MARK: - UI

    private func setupUI() {
        let switchRow = UIView()
        let switchTitle = UILabel()
        switchTitle.text = "启用均衡器"
        switchTitle.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        switchTitle.textColor = .label
        enableSwitch.isOn = ConfigStore.shared.eqEnabled
        enableSwitch.onTintColor = Theme.primary
        switchRow.addSubview(switchTitle)
        switchRow.addSubview(enableSwitch)
        switchTitle.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            switchTitle.leadingAnchor.constraint(equalTo: switchRow.leadingAnchor),
            switchTitle.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            enableSwitch.trailingAnchor.constraint(equalTo: switchRow.trailingAnchor),
            enableSwitch.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            switchRow.heightAnchor.constraint(equalToConstant: 44),
        ])
        enableSwitch.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            ConfigStore.shared.eqEnabled = self.enableSwitch.isOn
            AudioEqualizer.shared.refreshGains()
            // v1.0.144：开关切换立即重新挂载当前音轨（原来要切一次歌才生效）
            PlayerManager.shared.remountEqualizer()
            Logger.info("均衡器开关：\(self.enableSwitch.isOn ? "开" : "关")")
        }, for: .valueChanged)

        // 预设 chips
        presetScroll.showsHorizontalScrollIndicator = false
        presetScroll.translatesAutoresizingMaskIntoConstraints = false
        presetStack.axis = .horizontal
        presetStack.spacing = 8
        presetStack.translatesAutoresizingMaskIntoConstraints = false
        presetScroll.addSubview(presetStack)
        for preset in Self.presets {
            let btn = UIButton(type: .system)
            btn.setTitle(preset.name, for: .normal)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
            btn.layer.cornerRadius = 15
            btn.layer.borderWidth = 1
            btn.layer.borderColor = Theme.outlineVariant.cgColor
            btn.setTitleColor(.label, for: .normal)
            btn.addAction(UIAction { [weak self] _ in
                self?.applyPreset(preset.name)
            }, for: .touchUpInside)
            presetButtons.append(btn)
            presetStack.addArrangedSubview(btn)
        }

        // 10 根竖向滑杆
        gainStack.axis = .horizontal
        gainStack.distribution = .fillEqually
        gainStack.spacing = 2
        gainStack.translatesAutoresizingMaskIntoConstraints = false
        let current = ConfigStore.shared.eqGains
        for band in 0..<10 {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            // v1.0.147：容器加高 —— 滑杆行程 = 容器高度，矮容器会让可调范围被压缩
            // v1.0.148：再加高到 300，并把滑杆与上/下标签的间距从 6pt 收到 4/2pt、
            // 频率标签贴容器底 —— 原来 thumb 到底时下方还空一截，视觉上「没到底」
            container.heightAnchor.constraint(equalToConstant: 300).isActive = true

            let valueLabel = UILabel()
            valueLabel.font = UIFont.systemFont(ofSize: 10)
            valueLabel.textColor = Theme.primary
            valueLabel.textAlignment = .center
            valueLabel.text = String(format: "%+.0f", current[band])

            // v1.0.147：改用自绘竖直滑杆 —— UISlider 旋转后 thumb 中心最多只能走
            // 「控件长度 − thumb 直径」，视觉上最大/最小都只在中段变化。自绘版把轨道
            // 上下端各内缩一个 thumb 半径，thumb 能真正走到顶端(+12dB)/底端(−12dB)。
            let slider = GainSlider()
            slider.minimumValue = -AudioEqualizer.maxGainDb
            slider.maximumValue = AudioEqualizer.maxGainDb
            slider.value = current[band]
            slider.tag = band
            slider.addTarget(self, action: #selector(gainChanged(_:)), for: .valueChanged)

            let freqLabel = UILabel()
            freqLabel.font = UIFont.systemFont(ofSize: 11)
            freqLabel.textColor = .secondaryLabel
            freqLabel.textAlignment = .center
            freqLabel.text = AudioEqualizer.bandLabels[band]

            container.addSubview(valueLabel)
            container.addSubview(slider)
            container.addSubview(freqLabel)
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            slider.translatesAutoresizingMaskIntoConstraints = false
            freqLabel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                valueLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                valueLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

                slider.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                // v1.0.147：滑杆上下贴住数值/频率标签 —— 行程吃满容器可用高度
                slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
                slider.bottomAnchor.constraint(equalTo: freqLabel.topAnchor, constant: -2),
                slider.widthAnchor.constraint(equalToConstant: 32),

                freqLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 0),
                freqLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            ])
            sliders.append(slider)
            valueLabels.append(valueLabel)
            gainStack.addArrangedSubview(container)
        }

        tipLabel.font = UIFont.systemFont(ofSize: 12)
        tipLabel.textColor = .tertiaryLabel
        tipLabel.numberOfLines = 0
        tipLabel.text = "十段 EQ（31Hz~16kHz，±12dB）挂在播放音轨上实时生效。开启后若频谱无效，切一次歌即可重新挂载。"

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIStackView(arrangedSubviews: [switchRow, presetScroll, gainStack, tipLabel])
        content.axis = .vertical
        content.spacing = 18
        content.setCustomSpacing(10, after: switchRow)
        content.setCustomSpacing(6, after: presetScroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),

            presetStack.leadingAnchor.constraint(equalTo: presetScroll.leadingAnchor, constant: 0),
            presetStack.trailingAnchor.constraint(equalTo: presetScroll.trailingAnchor, constant: 0),
            presetStack.topAnchor.constraint(equalTo: presetScroll.topAnchor),
            presetStack.bottomAnchor.constraint(equalTo: presetScroll.bottomAnchor),
            presetScroll.heightAnchor.constraint(equalToConstant: 34),
        ])
        presetScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        presetScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
    }

    // MARK: - 动作

    @objc private func gainChanged(_ sender: GainSlider) {
        let band = sender.tag
        let v = sender.value.rounded()
        sender.value = v
        valueLabels[band].text = String(format: "%+.0f", v)
        AudioEqualizer.shared.setGain(band: band, value: v)
        selectPreset(matchingCurrent: true)
    }

    private func applyPreset(_ name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        let eq = AudioEqualizer.shared
        for band in 0..<10 {
            sliders[band].value = preset.gains[band]
            valueLabels[band].text = String(format: "%+.0f", preset.gains[band])
            eq.setGain(band: band, value: preset.gains[band])
        }
        highlightPreset(name)
    }

    private func selectPreset(matchingCurrent: Bool) {
        let gains = ConfigStore.shared.eqGains
        for preset in Self.presets where preset.gains == gains {
            highlightPreset(preset.name)
            return
        }
        highlightPreset("自定义")
    }

    private func highlightPreset(_ name: String) {
        for (i, btn) in presetButtons.enumerated() {
            let selected = btn.currentTitle == name
            btn.backgroundColor = selected ? Theme.primaryContainer : Theme.bg
            btn.setTitleColor(selected ? Theme.primary : .label, for: .normal)
            btn.layer.borderColor = selected ? Theme.primary.cgColor : Theme.outlineVariant.cgColor
            _ = i
        }
    }
}

/// v1.0.147：自绘竖直增益滑杆。
/// 用 UISlider + 旋转变竖直时，thumb 中心最多只能走「控件长度 − thumb 直径」，
/// 表现为「最大值/最小值都只在中段变化」。自绘版把轨道上下端各内缩一个 thumb 半径，
/// thumb 中心恰好能走到顶端（+12dB）与底端（−12dB），行程完全对应可调范围。
final class GainSlider: UIControl {

    var minimumValue: Float = -12
    var maximumValue: Float = 12
    var value: Float = 0 {
        didSet { if value != oldValue { setNeedsDisplay() } }
    }
    var trackColor: UIColor = UIColor.white.withAlphaComponent(0.18)
    var fillColor: UIColor = Theme.primary

    private let thumbRadius: CGFloat = 9
    private var travelTop: CGFloat { thumbRadius }
    private var travelBottom: CGFloat { max(thumbRadius, bounds.height - thumbRadius) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: 32, height: 220) }

    private func y(for v: Float) -> CGFloat {
        let span = max(0.0001, maximumValue - minimumValue)
        let t = CGFloat(max(0, min(1, (v - minimumValue) / span)))
        return travelBottom - t * (travelBottom - travelTop)
    }

    private func valueAt(y: CGFloat) -> Float {
        let span = travelBottom - travelTop
        guard span > 1 else { return minimumValue }
        let t = max(0, min(1, (travelBottom - y) / span))
        return minimumValue + Float(t) * (maximumValue - minimumValue)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let nv = valueAt(y: g.location(in: self).y)
            if abs(nv - value) > 0.05 {
                value = nv
                sendActions(for: .valueChanged)
            }
        default:
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.height > 20 else { return }
        let cx = bounds.midX
        let trackW: CGFloat = 5
        let curY = y(for: value)
        let zeroY = y(for: 0)

        // 轨道底色
        trackColor.setFill()
        UIBezierPath(roundedRect: CGRect(x: cx - trackW / 2, y: travelTop,
                                         width: trackW, height: travelBottom - travelTop),
                     cornerRadius: trackW / 2).fill()

        // 已调增益段（0dB → 当前值）
        if abs(curY - zeroY) > 1 {
            fillColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: cx - trackW / 2, y: min(zeroY, curY),
                                             width: trackW, height: abs(curY - zeroY)),
                         cornerRadius: trackW / 2).fill()
        }

        // 0dB 中线
        UIColor.white.withAlphaComponent(0.30).setFill()
        ctx.fill(CGRect(x: cx - 9, y: zeroY - 0.5, width: 18, height: 1))

        // thumb
        let knob = CGRect(x: cx - thumbRadius, y: curY - thumbRadius,
                          width: thumbRadius * 2, height: thumbRadius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        UIColor.white.setFill()
        ctx.fillEllipse(in: knob)
        ctx.restoreGState()
        fillColor.setStroke()
        let ring = UIBezierPath(ovalIn: knob.insetBy(dx: 2.5, dy: 2.5))
        ring.lineWidth = 2.5
        ring.stroke()
    }
}
