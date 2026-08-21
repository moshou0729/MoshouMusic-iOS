import UIKit

/// 设置页 — Material Design 3 风格
/// 音源管理 / 播放设置 / 悬浮歌词 / 外观 / 关于
class SettingsViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 计算属性：每次读取实时取配置，保证开关/副标题状态与 ConfigStore 同步
    private var sections: [SettingSection] {
        SettingSection(title: "音源管理", items: [
            SettingItem(icon: "music.note", iconColor: Theme.primary, title: "音源设置", subtitle: "管理音源脚本", type: .navigate),
            SettingItem(icon: "square.and.arrow.down", iconColor: Theme.tertiary, title: "导入脚本", subtitle: "从文件导入自定义源", type: .navigate),
        ]),
        SettingSection(title: "播放设置", items: [
            SettingItem(icon: "music.note.list", iconColor: Theme.secondary, title: "默认音质", subtitle: ConfigStore.shared.defaultQuality, type: .navigate),
            SettingItem(icon: "repeat", iconColor: Theme.warning, title: "播放模式", subtitle: PlayMode(rawValue: ConfigStore.shared.playMode)?.displayName ?? "列表循环", type: .navigate),
        ]),
        SettingSection(title: "悬浮歌词", items: [
            SettingItem(icon: "rectangle.expand.vertical", iconColor: Theme.primary, title: "悬浮歌词", subtitle: nil, type: .toggle(ConfigStore.shared.isFloatingLyricsOn)),
            SettingItem(icon: "circle.lefthalf.filled", iconColor: Theme.tertiary, title: "歌词透明度", subtitle: "\(Int(ConfigStore.shared.floatingOpacity * 100))%", type: .navigate),
        ]),
        SettingSection(title: "外观", items: [
            SettingItem(icon: "moon", iconColor: Theme.primary, title: "深色模式", subtitle: nil, type: .toggle(ConfigStore.shared.isDarkMode)),
        ]),
        SettingSection(title: "其他", items: [
            SettingItem(icon: "trash", iconColor: Theme.error, title: "清除缓存", subtitle: nil, type: .navigate),
            SettingItem(icon: "info.circle", iconColor: Theme.tertiary, title: "关于墨守music", subtitle: "v1.0.0", type: .navigate),
        ]),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "设置"

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SettingCell.self, forCellReuseIdentifier: SettingCell.reuseIdentifier)
        tableView.backgroundColor = Theme.bg
        tableView.separatorColor = Theme.outlineVariant
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

// MARK: - 数据模型

struct SettingSection {
    let title: String
    let items: [SettingItem]
}

struct SettingItem {
    let icon: String
    let iconColor: UIColor
    let title: String
    let subtitle: String?
    let type: ItemType

    enum ItemType {
        case toggle(Bool)
        case navigate
    }
}

// MARK: - UITableViewDataSource & Delegate

extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = Theme.primary
            header.textLabel?.font = Theme.labelLarge
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SettingCell.reuseIdentifier, for: indexPath) as! SettingCell
        let item = sections[indexPath.section].items[indexPath.row]
        cell.configure(with: item)
        cell.onToggle = { [weak self] isOn in
            self?.handleToggle(indexPath: indexPath, isOn: isOn)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        handleNavigate(indexPath: indexPath)
    }

    // MARK: - 处理

    private func handleToggle(indexPath: IndexPath, isOn: Bool) {
        let section = sections[indexPath.section]
        let item = section.items[indexPath.row]

        switch item.title {
        case "悬浮歌词":
            ConfigStore.shared.isFloatingLyricsOn = isOn
            if isOn {
                FloatingLyricsManager.shared.show()
            } else {
                FloatingLyricsManager.shared.hide()
            }
        case "深色模式":
            ConfigStore.shared.isDarkMode = isOn
            Theme.applyAppearance()
            rebuildWindow()
        default:
            break
        }
    }

    /// 深浅模式切换后重建整个界面树
    private func rebuildWindow() {
        guard let window = view.window else { return }
        window.overrideUserInterfaceStyle = ConfigStore.shared.isDarkMode ? .dark : .light
        let newRoot = MainTabBarController()
        UIView.transition(
            with: window,
            duration: 0.25,
            options: .transitionCrossDissolve,
            animations: { window.rootViewController = newRoot },
            completion: nil
        )
    }

    private func handleNavigate(indexPath: IndexPath) {
        let section = sections[indexPath.section]
        let item = section.items[indexPath.row]

        switch item.title {
        case "音源设置":
            navigationController?.pushViewController(SourceSettingsViewController(), animated: true)
        case "关于墨守music":
            navigationController?.pushViewController(AboutViewController(), animated: true)
        case "清除缓存":
            ConfigStore.shared.clearCache()
            showAlert(title: "已清除缓存", message: "缓存已清理完成")
        default:
            showAlert(title: "功能开发中", message: "\(item.title) 即将上线")
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - SettingCell

class SettingCell: UITableViewCell {

    static let reuseIdentifier = "SettingCell"

    private let iconView = UIView()
    private let iconImage = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let toggleSwitch = UISwitch()
    private let arrowView = UIImageView()

    /// 有副标题时激活（标题+副标题布局）；无副标题时激活 titleBottomConstraint
    private var subtitleBottomConstraint: NSLayoutConstraint!
    private var titleBottomConstraint: NSLayoutConstraint!

    var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        selectionStyle = .none

        iconView.layer.cornerRadius = 8
        contentView.addSubview(iconView)

        iconImage.contentMode = .scaleAspectFit
        iconImage.tintColor = .white
        iconView.addSubview(iconImage)

        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        contentView.addSubview(titleLabel)

        subtitleLabel.font = Theme.bodySmall
        subtitleLabel.textColor = Theme.subtext
        contentView.addSubview(subtitleLabel)

        toggleSwitch.onTintColor = Theme.primary
        toggleSwitch.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        contentView.addSubview(toggleSwitch)

        arrowView.image = UIImage(systemName: "chevron.right")?
            .withTintColor(Theme.outline, renderingMode: .alwaysOriginal)
        contentView.addSubview(arrowView)

        [iconView, iconImage, titleLabel, subtitleLabel, toggleSwitch, arrowView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 图标：居中 + 固定尺寸（不与文字链抢行高，消除约束冲突）
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            iconImage.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconImage.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            iconImage.widthAnchor.constraint(equalToConstant: 18),
            iconImage.heightAnchor.constraint(equalToConstant: 18),

            // 标题：有尾部约束，避免长文字钻到开关/箭头下面
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -72),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -72),

            toggleSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            toggleSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            arrowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            arrowView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            arrowView.widthAnchor.constraint(equalToConstant: 12),
            arrowView.heightAnchor.constraint(equalToConstant: 16),
        ])

        // 两套行底约束：有副标题时挂副标题底部，无副标题时挂标题底部
        subtitleBottomConstraint = subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        titleBottomConstraint = titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
    }

    func configure(with item: SettingItem) {
        contentView.backgroundColor = Theme.cardBg
        backgroundColor = .clear

        iconView.backgroundColor = item.iconColor
        iconImage.image = UIImage(systemName: item.icon)
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle

        if item.subtitle == nil {
            subtitleLabel.isHidden = true
            subtitleBottomConstraint.isActive = false
            titleBottomConstraint.isActive = true
        } else {
            subtitleLabel.isHidden = false
            titleBottomConstraint.isActive = false
            subtitleBottomConstraint.isActive = true
        }

        switch item.type {
        case .toggle(let isOn):
            toggleSwitch.isHidden = false
            toggleSwitch.isOn = isOn
            arrowView.isHidden = true
        case .navigate:
            toggleSwitch.isHidden = true
            arrowView.isHidden = false
        }
    }

    @objc private func toggleChanged() {
        onToggle?(toggleSwitch.isOn)
    }
}

// MARK: - 子页面

class SourceSettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let sources = ["kw", "tx", "mg", "wy", "kg"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "音源设置"
        view.backgroundColor = Theme.bg
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SourceCell")
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sources.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell", for: indexPath)
        let source = sources[indexPath.row]
        cell.textLabel?.text = Theme.sourceName(source)
        cell.textLabel?.textColor = Theme.text
        cell.imageView?.image = UIImage(systemName: "music.note")?
            .withTintColor(Theme.sourceColor(source), renderingMode: .alwaysOriginal)

        let toggle = UISwitch()
        toggle.onTintColor = Theme.sourceColor(source)
        toggle.isOn = ConfigStore.shared.isSourceEnabled(source)
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(sourceToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        cell.backgroundColor = Theme.cardBg
        return cell
    }

    @objc private func sourceToggled(_ sender: UISwitch) {
        let source = sources[sender.tag]
        ConfigStore.shared.setSource(source, enabled: sender.isOn)
        ScriptManager.shared.scanScripts()
    }
}

class AboutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "关于"
        view.backgroundColor = Theme.bg

        let label = UILabel()
        label.text = "墨守music v1.0.0\n墨韵守音 · 巨魔音乐\n\n参考 LXMusic Mobile 架构\n独立开发，兼容社区脚本"
        label.font = Theme.bodyLarge
        label.textColor = Theme.text
        label.textAlignment = .center
        label.numberOfLines = 0
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])
    }
}
