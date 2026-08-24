import UIKit

/// 默认音质选择
class QualityPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let options: [(id: String, label: String)] = [
        ("128k", "标准 128k"),
        ("320k", "高品质 320k"),
        ("flac", "无损 FLAC")
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "默认音质"
        view.backgroundColor = Theme.bg
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let opt = options[indexPath.row]
        cell.textLabel?.text = opt.label
        cell.textLabel?.textColor = Theme.text
        cell.backgroundColor = Theme.cardBg
        cell.tintColor = Theme.primary
        cell.accessoryType = ConfigStore.shared.defaultQuality == opt.id ? .checkmark : .none
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        ConfigStore.shared.defaultQuality = options[indexPath.row].id
        navigationController?.popViewController(animated: true)
    }
}

/// 播放模式选择
class PlayModePickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "播放模式"
        view.backgroundColor = Theme.bg
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { PlayMode.allCases.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let mode = PlayMode.allCases[indexPath.row]
        cell.textLabel?.text = mode.displayName
        cell.textLabel?.textColor = Theme.text
        cell.backgroundColor = Theme.cardBg
        cell.tintColor = Theme.primary
        cell.accessoryType = ConfigStore.shared.playMode == mode.rawValue ? .checkmark : .none
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        ConfigStore.shared.playMode = PlayMode.allCases[indexPath.row].rawValue
        navigationController?.popViewController(animated: true)
    }
}

/// 歌词透明度调节
class OpacityViewController: UIViewController {
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private let demoLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "歌词透明度"
        view.backgroundColor = Theme.bg
        setupUI()
    }

    private func setupUI() {
        valueLabel.text = "\(Int(ConfigStore.shared.floatingOpacity * 100))%"
        valueLabel.font = Theme.titleMedium
        valueLabel.textColor = Theme.primary
        valueLabel.textAlignment = .center

        slider.minimumValue = 0.2
        slider.maximumValue = 1.0
        slider.value = ConfigStore.shared.floatingOpacity
        slider.tintColor = Theme.primary
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        demoLabel.text = "墨韵守音 · 歌词预览"
        demoLabel.font = Theme.titleLarge
        demoLabel.textColor = .white
        demoLabel.textAlignment = .center
        demoLabel.backgroundColor = Theme.primary.withAlphaComponent(CGFloat(slider.value))
        demoLabel.layer.cornerRadius = Theme.cornerMedium
        demoLabel.layer.masksToBounds = true
        demoLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [valueLabel, slider, demoLabel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func sliderChanged() {
        let v = slider.value
        ConfigStore.shared.floatingOpacity = v
        valueLabel.text = "\(Int(v * 100))%"
        demoLabel.backgroundColor = Theme.primary.withAlphaComponent(CGFloat(v))
        FloatingLyricsManager.shared.updateOpacity(v)
    }
}
