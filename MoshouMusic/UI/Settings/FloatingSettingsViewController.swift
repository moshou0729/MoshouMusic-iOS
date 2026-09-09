import UIKit

/// 悬浮歌词设置 —— 窗口大小 / 字号 / 背景透明度手动调节，位置重置
final class FloatingSettingsViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let switchControl = UISwitch()
    private lazy var widthRow = SliderRow(title: "宽度", value: Float(ConfigStore.shared.floatingSize.width),
                                          min: 140, max: Float(UIScreen.main.bounds.width) - 16) { "\(Int($0)) pt" }
    private lazy var heightRow = SliderRow(title: "高度", value: Float(ConfigStore.shared.floatingSize.height),
                                           min: 72, max: 360) { "\(Int($0)) pt" }
    private lazy var fontRow = SliderRow(title: "字号", value: Float(ConfigStore.shared.floatingFontSize),
                                         min: 10, max: 34) { "\(Int($0)) 号" }
    private lazy var opacityRow = SliderRow(title: "背景透明度", value: ConfigStore.shared.floatingOpacity,
                                            min: 0.1, max: 1.0) { "\(Int($0 * 100))%" }

    private let statusLabel = UILabel()
    private let tipLabel = UILabel()
    private let resetButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "悬浮歌词设置"
        view.backgroundColor = Theme.bg
        setupUI()
        bindActions()
        refreshStatus()
    }

    // MARK: - UI

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
        ])

        // 开关行
        let switchRow = UIView()
        let switchTitle = UILabel()
        switchTitle.text = "启用悬浮歌词"
        switchTitle.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        switchTitle.textColor = .label
        switchControl.isOn = ConfigStore.shared.isFloatingLyricsOn
        switchControl.onTintColor = Theme.primary
        switchRow.addSubview(switchTitle)
        switchRow.addSubview(switchControl)
        switchTitle.translatesAutoresizingMaskIntoConstraints = false
        switchControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            switchTitle.leadingAnchor.constraint(equalTo: switchRow.leadingAnchor),
            switchTitle.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            switchControl.trailingAnchor.constraint(equalTo: switchRow.trailingAnchor),
            switchControl.centerYAnchor.constraint(equalTo: switchRow.centerYAnchor),
            switchRow.heightAnchor.constraint(equalToConstant: 44),
        ])

        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        tipLabel.font = UIFont.systemFont(ofSize: 12)
        tipLabel.textColor = .tertiaryLabel
        tipLabel.numberOfLines = 0
        tipLabel.text = "拖动悬浮框可移动位置，双指捏合可缩放大小，双击可锁定（锁定后不响应拖动、背景变淡）。"

        resetButton.setTitle("恢复默认大小与位置", for: .normal)
        resetButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        resetButton.setTitleColor(Theme.primary, for: .normal)

        [switchRow, statusLabel, widthRow, heightRow, fontRow, opacityRow, colorRow, resetButton, tipLabel]
            .forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(6, after: switchRow)
        stack.setCustomSpacing(24, after: statusLabel)
        stack.setCustomSpacing(24, after: colorRow)
        colorRow.heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func bindActions() {
        switchControl.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)

        widthRow.onChanged = { [weak self] value in
            var size = ConfigStore.shared.floatingSize
            size.width = CGFloat(value)
            ConfigStore.shared.floatingSize = size
            self?.apply()
        }
        heightRow.onChanged = { [weak self] value in
            var size = ConfigStore.shared.floatingSize
            size.height = CGFloat(value)
            ConfigStore.shared.floatingSize = size
            self?.apply()
        }
        fontRow.onChanged = { [weak self] value in
            ConfigStore.shared.floatingFontSize = CGFloat(value)
            self?.apply()
        }
        opacityRow.onChanged = { [weak self] value in
            self?.updateOpacity(value)
        }
        // 滑杆拖动中只做局部更新；松手时强制 SB 全量重合成，消除脏区残影
        [widthRow, heightRow, fontRow, opacityRow].forEach { row in
            row.onEnded = { FloatingLyricsManager.shared.forceRecomposite() }
        }
        colorRow.onSelect = { hex in
            FloatingLyricsManager.shared.updateBgColor(hex: hex)
        }
        colorRow.onCustom = { [weak self] in
            guard let self = self else { return }
            let picker = UIColorPickerViewController()
            picker.title = "悬浮歌词背景颜色"
            picker.supportsAlpha = false
            picker.selectedColor = UIColor(hex: ConfigStore.shared.floatingBgColorHex)
            picker.delegate = self
            self.present(picker, animated: true)
        }
        resetButton.addTarget(self, action: #selector(resetLayout), for: .touchUpInside)
    }

    private func apply() {
        FloatingLyricsManager.shared.applySettings()
    }

    private func updateOpacity(_ value: Float) {
        FloatingLyricsManager.shared.updateOpacity(value)
    }

    // MARK: - Actions

    @objc private func toggleChanged() {
        let isOn = switchControl.isOn
        ConfigStore.shared.isFloatingLyricsOn = isOn
        if isOn {
            FloatingLyricsManager.shared.show()
        } else {
            FloatingLyricsManager.shared.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc private func resetLayout() {
        ConfigStore.shared.resetFloatingLayout()
        widthRow.set(value: Float(ConfigStore.shared.floatingSize.width))
        heightRow.set(value: Float(ConfigStore.shared.floatingSize.height))
        fontRow.set(value: Float(ConfigStore.shared.floatingFontSize))
        apply()
    }

    private func refreshStatus() {
        let text = FloatingLyricsManager.shared.diagnosticText()
        statusLabel.text = text
        statusLabel.textColor = FloatingLyricsManager.shared.isGlobalWindowReady
            ? Theme.primary : .secondaryLabel
    }
}

// MARK: - 滑杆行

private final class SliderRow: UIView {

    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let formatter: (Float) -> String

    var onChanged: ((Float) -> Void)?

    init(title: String, value: Float, min: Float, max: Float,
         format: @escaping (Float) -> String) {
        self.formatter = format
        super.init(frame: .zero)
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        slider.tintColor = Theme.primary
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        nameLabel.text = title
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .label

        valueLabel.font = UIFont.systemFont(ofSize: 14)
        valueLabel.textColor = Theme.primary
        valueLabel.textAlignment = .right
        valueLabel.text = format(value)

        let header = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
        header.axis = .horizontal
        header.distribution = .equalSpacing

        let container = UIStackView(arrangedSubviews: [header, slider])
        container.axis = .vertical
        container.spacing = 6
        addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: Float) {
        slider.value = value
        valueLabel.text = formatter(value)
    }

    var onEnded: (() -> Void)?

    @objc private func valueChanged() {
        let v = slider.value
        valueLabel.text = formatter(v)
        onChanged?(v)
    }

    @objc private func touchUp() {
        onEnded?()
    }
}

// MARK: - 背景颜色行（预设色板 + 自定义取色）

private final class ColorRow: UIView {

    static let presets: [(String, UInt32)] = [
        ("黑", 0x000000), ("深灰", 0x1C1C1E), ("白", 0xF2F2F7),
        ("红", 0xE53935), ("橙", 0xFB8C00), ("绿", 0x43A047),
        ("蓝", 0x1E88E5), ("紫", 0x8E24AA), ("粉", 0xD81B60),
    ]

    var onSelect: ((UInt32) -> Void)?
    var onCustom: (() -> Void)?

    private var swatchButtons: [UIButton] = []
    private let customButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        let nameLabel = UILabel()
        nameLabel.text = "背景颜色"
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .label
        addSubview(nameLabel)

        let swatches = UIStackView()
        swatches.axis = .horizontal
        swatches.spacing = 10
        swatches.alignment = .center
        addSubview(swatches)

        for (index, (_, hex)) in Self.presets.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.layer.cornerRadius = 14
            button.backgroundColor = UIColor(hex: hex)
            button.layer.borderWidth = 0
            button.layer.borderColor = UIColor.secondaryLabel.cgColor
            button.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            swatches.addArrangedSubview(button)
            swatchButtons.append(button)
        }

        customButton.setTitle("自定义", for: .normal)
        customButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        customButton.setTitleColor(Theme.primary, for: .normal)
        customButton.addTarget(self, action: #selector(customTapped), for: .touchUpInside)
        swatches.addArrangedSubview(customButton)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        swatches.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatches.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 16),
            swatches.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            swatches.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshSelection() {
        let current = ConfigStore.shared.floatingBgColorHex
        for (index, button) in swatchButtons.enumerated() {
            let selected = Self.presets.indices.contains(index) && Self.presets[index].1 == current
            button.layer.borderWidth = selected ? 2 : 0
        }
    }

    @objc private func swatchTapped(_ sender: UIButton) {
        let index = sender.tag
        guard Self.presets.indices.contains(index) else { return }
        let hex = Self.presets[index].1
        ConfigStore.shared.floatingBgColorHex = hex
        refreshSelection()
        onSelect?(hex)
    }

    @objc private func customTapped() {
        onCustom?()
    }
}

// MARK: - 系统取色器回调

extension FloatingSettingsViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        applyPicked(viewController.selectedColor)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                   didSelect color: UIColor, continuously: Bool) {
        guard !continuously else { return }
        applyPicked(color)
    }

    private func applyPicked(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = UInt32(round(r * 255)) << 16 | UInt32(round(g * 255)) << 8 | UInt32(round(b * 255))
        ConfigStore.shared.floatingBgColorHex = hex
        FloatingLyricsManager.shared.updateBgColor(hex: hex)
        colorRow.refreshSelection()
    }
}
