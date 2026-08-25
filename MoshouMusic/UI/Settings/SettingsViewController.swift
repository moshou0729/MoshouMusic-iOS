import UIKit
import UniformTypeIdentifiers

/// 读取 App 真实版本号（来自 Info.plist，由 CI 在每次构建时自动 +1 patch）
enum AppInfo {
    static var shortVersion: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}

/// 设置页 — Material Design 3 风格
/// 音源管理 / 播放设置 / 悬浮歌词 / 外观 / 关于
class SettingsViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 已启用且脚本已加载的音源数量，用于「音源管理」副标题
    private var sourceSummary: String {
        let all = ConfigStore.shared.selectableSourceIds
        let enabled = all.filter { ConfigStore.shared.isSourceEnabled($0) }
        let ready = enabled.filter { ScriptEngine.shared.hasHandler(for: $0) }
        return "已启用 \(enabled.count)/\(all.count) 个 · 可用 \(ready.count) 个"
    }

    /// 计算属性：每次读取实时取配置，保证开关/副标题状态与 ConfigStore 同步
    private var sections: [SettingSection] {
        return [
        // 原来「音源设置」和「导入脚本」两条都跳同一个页面，属于重复入口，已合并为一条
        SettingSection(title: "音源管理", items: [
            SettingItem(icon: "music.note", iconColor: Theme.primary, title: "音源管理", subtitle: sourceSummary, type: .navigate),
        ]),
        SettingSection(title: "播放设置", items: [
            SettingItem(icon: "music.note.list", iconColor: Theme.secondary, title: "默认音质", subtitle: ConfigStore.shared.defaultQuality, type: .navigate),
            SettingItem(icon: "repeat", iconColor: Theme.warning, title: "播放模式", subtitle: PlayMode(rawValue: ConfigStore.shared.playMode)?.displayName ?? "列表循环", type: .navigate),
            SettingItem(icon: "arrow.triangle.2.circlepath", iconColor: Theme.secondary, title: "自动换源", subtitle: "当前音源播不出时自动换别的源", type: .toggle(ConfigStore.shared.autoSwitchSource)),
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
            SettingItem(icon: "info.circle", iconColor: Theme.tertiary, title: "关于墨守music", subtitle: "v\(AppInfo.shortVersion)", type: .navigate),
        ]),
        ]
    }

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
        case "自动换源":
            ConfigStore.shared.autoSwitchSource = isOn
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
        case "音源管理":
            // 音源开关 + 添加/删除自定义脚本，全部收在这一个页面里
            navigationController?.pushViewController(SourceSettingsViewController(), animated: true)
        case "默认音质":
            navigationController?.pushViewController(QualityPickerViewController(), animated: true)
        case "播放模式":
            navigationController?.pushViewController(PlayModePickerViewController(), animated: true)
        case "歌词透明度":
            navigationController?.pushViewController(OpacityViewController(), animated: true)
        case "关于墨守music":
            navigationController?.pushViewController(AboutViewController(), animated: true)
        case "清除缓存":
            ConfigStore.shared.clearCache()
            showAlert(title: "已清除缓存", message: "缓存已清理完成")
        default:
            showAlert(title: "功能开发中", message: "\(item.title) 即将上线")
        }
    }

    // 脚本导入统一放在「音源管理」页，这里不再持有文档选择器

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
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -76),
        ])

        setupAddButton()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "粘贴添加", style: .plain, target: self, action: #selector(openAddForm)
        )
    }

    /// 底部醒目的「添加音源」主按钮（默认走最可靠的「手动粘贴代码」路径）
    private func setupAddButton() {
        let addBtn = UIButton(type: .system)
        addBtn.setTitle("+ 添加音源", for: .normal)
        addBtn.titleLabel?.font = Theme.titleMedium
        addBtn.setTitleColor(.white, for: .normal)
        addBtn.backgroundColor = Theme.error
        addBtn.layer.cornerRadius = Theme.cornerLarge
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.addTarget(self, action: #selector(openAddForm), for: .touchUpInside)
        view.addSubview(addBtn)
        NSLayoutConstraint.activate([
            addBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            addBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            addBtn.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private var sources: [String] { ConfigStore.shared.selectableSourceIds }

    // 区分内置 / 自定义音源
    private func isCustom(_ source: String) -> Bool {
        return ConfigStore.shared.customSources[source] != nil
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sources.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell", for: indexPath)
        let source = sources[indexPath.row]
        cell.textLabel?.text = ConfigStore.shared.displayName(for: source)
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

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return isCustom(sources[indexPath.row])
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let source = sources[indexPath.row]
        removeCustomSource(source)
    }

    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return "删除"
    }

    @objc private func sourceToggled(_ sender: UISwitch) {
        let source = sources[sender.tag]
        ConfigStore.shared.setSource(source, enabled: sender.isOn)
        ScriptManager.shared.scanScripts()
    }

    // MARK: - 添加音源

    // 右上「+」：选择导入方式（文件 / 粘贴）
    @objc private func addSourceTapped() {
        let alert = UIAlertController(title: "添加音源", message: "从文件导入在 TrollStore 沙盒下可能选不到文件，推荐「手动粘贴代码」", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "手动粘贴代码 (推荐)", style: .default) { [weak self] _ in
            self?.openAddForm()
        })
        alert.addAction(UIAlertAction(title: "从文件导入 (.js)", style: .default) { [weak self] _ in
            self?.presentImportPicker()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // 底部主按钮：直接进入粘贴代码表单（最可靠路径）
    @objc private func openAddForm() {
        let vc = AddSourceViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    private func presentImportPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "js") ?? .plainText, .plainText])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)

        // TrollStore 沙盒下文档选择器常无回调，加超时兜底提示
        importPickerTimeout?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.showAlert(
                title: "文件导入可能不可用",
                message: "在 TrollStore 环境下系统文件选择器经常选不到文件。建议改用「粘贴代码」：复制 .js 内容 → 返回点「+ 添加音源」→ 粘贴保存。"
            )
        }
        importPickerTimeout = timer
    }

    private var importPickerTimeout: Timer?

    private func removeCustomSource(_ source: String) {
        let url = ConfigStore.shared.scriptsDirectory.appendingPathComponent(source + ".js")
        try? FileManager.default.removeItem(at: url)
        ConfigStore.shared.removeCustomSource(id: source)
        ScriptManager.shared.scanScripts()
        tableView.reloadData()
    }

    // MARK: - 文档导入

    private func importScript(at url: URL) {
        guard url.pathExtension.lowercased() == "js" else {
            showAlert(title: "格式不支持", message: "请选择 .js 音源脚本")
            return
        }
        let ok = ScriptManager.shared.importScript(url: url)
        showAlert(title: ok ? "导入成功" : "导入失败",
                  message: ok ? "脚本已加入音源" : "请检查脚本格式后重试")
        tableView.reloadData()
    }

    private func showAlert(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension SourceSettingsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
        guard let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        importScript(at: url)
        if secured { url.stopAccessingSecurityScopedResource() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
    }
}

class AboutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "关于"
        view.backgroundColor = Theme.bg

        let label = UILabel()
        label.text = "墨守music v\(AppInfo.shortVersion)\n墨韵守音 · 巨魔音乐\n\n参考 LXMusic Mobile 架构\n独立开发，兼容社区脚本"
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
