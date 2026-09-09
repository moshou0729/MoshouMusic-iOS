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

        [switchRow, statusLabel, widthRow, heightRow, fontRow, opacityRow, resetButton, tipLabel]
            .forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(6, after: switchRow)
        stack.setCustomSpacing(24, after: statusLabel)
        stack.setCustomSpacing(24, after: opacityRow)
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
        if FloatingLyricsManager.shared.isGlobalWindowReady {
            statusLabel.text = "状态：已注册系统级窗口，切到其他应用 / 主屏 / 锁屏后依然显示。"
            statusLabel.textColor = Theme.primary
        } else if ConfigStore.shared.isFloatingLyricsOn {
            statusLabel.text = "状态：未取得系统级窗口权限，悬浮歌词仅在应用内可见（需 TrollStore 安装）。"
            statusLabel.textColor = .secondaryLabel
        } else {
            statusLabel.text = "状态：未启用。"
            statusLabel.textColor = .secondaryLabel
        }
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

    @objc private func valueChanged() {
        let v = slider.value
        valueLabel.text = formatter(v)
        onChanged?(v)
    }
}
