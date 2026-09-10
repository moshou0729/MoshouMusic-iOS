import UIKit

/// v1.0.141：十段均衡器设置页 —— 10 根竖向滑杆 + 预设方案，实时生效。
final class EqualizerViewController: UIViewController {

    private let enableSwitch = UISwitch()
    private let presetScroll = UIScrollView()
    private let presetStack = UIStackView()
    private let gainStack = UIStackView()
    private var sliders: [UISlider] = []
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
            container.heightAnchor.constraint(equalToConstant: 190).isActive = true

            let valueLabel = UILabel()
            valueLabel.font = UIFont.systemFont(ofSize: 10)
            valueLabel.textColor = Theme.primary
            valueLabel.textAlignment = .center
            valueLabel.text = String(format: "%+.0f", current[band])

            let slider = UISlider()
            slider.minimumValue = -AudioEqualizer.maxGainDb
            slider.maximumValue = AudioEqualizer.maxGainDb
            slider.value = current[band]
            slider.tintColor = Theme.primary
            slider.isContinuous = true
            slider.tag = band
            slider.frame = CGRect(x: 0, y: 0, width: 160, height: 32)
            slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
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
                slider.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 8),

                freqLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
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

    @objc private func gainChanged(_ sender: UISlider) {
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
            sliders[band].setValue(preset.gains[band], animated: true)
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
