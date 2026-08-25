import UIKit

/// 洛雪(lx-music)社区音源管理页
/// 列出已加载的 LX 兼容脚本（内置预设 + 用户导入），支持导入与删除（仅用户脚本）
class LXMusicViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var scripts: [(id: String, name: String, platforms: [String], isUser: Bool)] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "洛雪社区音源"
        view.backgroundColor = Theme.bg

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LXCell")
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -76),
        ])

        setupImportButton()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "粘贴导入", style: .plain, target: self, action: #selector(openImport)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        LXCompatEngine.shared.ensureLoaded()
        scripts = LXCompatEngine.shared.scriptList
        tableView.reloadData()
    }

    private func setupImportButton() {
        let btn = UIButton(type: .system)
        btn.setTitle("+ 导入洛雪脚本", for: .normal)
        btn.titleLabel?.font = Theme.titleMedium
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = Theme.primary
        btn.layer.cornerRadius = Theme.cornerLarge
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(openImport), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            btn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            btn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            btn.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func openImport() {
        let vc = AddSourceViewController()
        vc.lxMode = true
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return scripts.isEmpty ? 1 : scripts.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "已加载的 LX 兼容音源（作为播放链接补充）"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LXCell", for: indexPath)
        cell.backgroundColor = Theme.cardBg
        cell.textLabel?.textColor = Theme.text
        cell.detailTextLabel?.textColor = Theme.subtext

        if scripts.isEmpty {
            cell.textLabel?.text = "暂无洛雪音源"
            cell.detailTextLabel?.text = "点下方按钮导入 .js 脚本"
            cell.accessoryType = .none
            return cell
        }

        let s = scripts[indexPath.row]
        cell.textLabel?.text = s.name + (s.isUser ? "  (本地)" : "  (预设)")
        if s.platforms.isEmpty {
            cell.detailTextLabel?.text = "未声明可用平台"
        } else {
            cell.detailTextLabel?.text = "平台: " + s.platforms.joined(separator: ", ")
        }
        cell.accessoryType = .none
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return !scripts.isEmpty && scripts[indexPath.row].isUser
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, !scripts.isEmpty else { return }
        let s = scripts[indexPath.row]
        let alert = UIAlertController(
            title: "删除音源",
            message: "确定删除「\(s.name)」？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            LXCompatEngine.shared.removeUserScript(id: s.id)
            self?.scripts = LXCompatEngine.shared.scriptList
            tableView.deleteRows(at: [indexPath], with: .automatic)
        })
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return "删除"
    }
}
