import UIKit
import CoreFoundation

/// 从 App 自己的文档目录里挑 .js 音源脚本 —— 绕开系统文件选择器
///
/// 为什么不用 UIDocumentPickerViewController：TrollStore 环境下系统文档选择器
/// 经常选不到文件、回调也不送达（v1.0.170 前已多次实测）。
/// 而 UIFileSharingEnabled 已开启，App 的 Documents 在「文件」App ▸ 我的 iPhone ▸ 墨守music
/// 里可直接看到，用户把 .js 拷进去后，这里扫一遍就能导入，比粘贴几万字符可靠得多。
class LocalScriptPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    enum ImportMode {
        case lxScript        // 洛雪社区脚本 → LXCompatEngine
        case builtinScript   // 普通自定义音源 → ScriptManager
    }

    struct Item {
        let url: URL
        let name: String
        let size: Int
        let modified: Date?
    }

    var mode: ImportMode = .lxScript

    /// 非空时进入「单选回调」模式：点中一个文件立即回填给调用方，不执行导入
    var onPick: ((URL, String) -> Void)?

    /// 函数类型无法直接用 `== nil` 判空，统一走这个标记
    private var isPickMode: Bool {
        if case .some = onPick { return true }
        return false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var items: [Item] = []
    private var selected: Set<Int> = []
    private let emptyLabel = UILabel()
    private let importButton = UIButton(type: .system)

    /// 批量导入的累计结果（串行执行，逐个等 LX 的同步/异步回调）
    private var importSucceed: [(name: String, platforms: [String])] = []
    private var importFailed: [String] = []

    /// 这些目录是「已导入脚本」的落盘位置，不再重复列出
    private static let excludedDirs: Set<String> = ["scripts", "lx_user_sources"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isPickMode ? "选择脚本文件" : "从文件夹导入"
        view.backgroundColor = Theme.bg

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.bg
        tableView.allowsMultipleSelection = false
        tableView.tableHeaderView = makeHeader()
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let bottomSafe: CGFloat = isPickMode ? 8 : 76
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -bottomSafe),
        ])

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        tableView.refreshControl = refresh

        setupEmptyLabel()

        if !isPickMode {
            setupImportButton()
        }

        reload()
    }

    // MARK: - 扫描

    @objc private func reload() {
        items = Self.scanJSFiles()
        selected.removeAll()
        tableView.reloadData()
        tableView.refreshControl?.endRefreshing()
        emptyLabel.isHidden = !items.isEmpty
        updateImportButton()
    }

    /// 扫描 Documents（含一层子目录，Inbox 也扫）下的 .js 文件
    static func scanJSFiles() -> [Item] {
        let fm = FileManager.default
        let docs = ConfigStore.shared.documentsDirectory
        var found: [Item] = []

        func collect(_ dir: URL, depth: Int) {
            guard depth <= 1 else { return }
            let list = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in list {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                if vals?.isDirectory == true {
                    // Inbox（系统「存储到文件 / 分享」进来的）也要扫；
                    // scripts / lx_user_sources 是导入后的落盘处，跳过
                    if !Self.excludedDirs.contains(url.lastPathComponent) {
                        collect(url, depth: depth + 1)
                    }
                    continue
                }
                guard url.pathExtension.lowercased() == "js" else { continue }
                found.append(Item(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    size: vals?.fileSize ?? 0,
                    modified: vals?.contentModificationDate
                ))
            }
        }

        collect(docs, depth: 0)
        found.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return found
    }

    // MARK: - 读取 / id

    /// UTF-8 优先，其次 GB18030（国内脚本常见），最后 ISO-Latin-1 兜底
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let s = String(data: data, encoding: gb) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 文件名 → 音源 id（只保留小写字母数字与下划线）
    static func makeID(from name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        // 用 unicodeScalars 判范围，避免依赖 Character 的比较运算符
        for scalar in lowered.unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        while out.hasPrefix("_") { out.removeFirst() }
        return out.isEmpty ? "script_\(Int(Date().timeIntervalSince1970))" : out
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    // MARK: - UI

    private func makeHeader() -> UIView {
        let wrap = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 74))
        let label = UILabel()
        label.text = "把 .js 音源文件放进「文件」App ▸ 我的 iPhone ▸ 墨守music（电脑可通过文件共享直接拖入），然后下拉刷新并勾选导入。"
        label.font = Theme.bodySmall
        label.textColor = Theme.subtext
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        return wrap
    }

    private func setupEmptyLabel() {
        emptyLabel.text = "文档目录里还没有 .js 文件\n\n把音源脚本拷进「文件」App ▸ 我的 iPhone ▸ 墨守music，\n再下拉刷新即可。"
        emptyLabel.font = Theme.bodyMedium
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func setupImportButton() {
        importButton.setTitle("导入选中", for: .normal)
        importButton.titleLabel?.font = Theme.titleMedium
        importButton.setTitleColor(.white, for: .normal)
        importButton.backgroundColor = Theme.primary
        importButton.layer.cornerRadius = Theme.cornerLarge
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        view.addSubview(importButton)
        NSLayoutConstraint.activate([
            importButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            importButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            importButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            importButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func updateImportButton() {
        guard !isPickMode else { return }
        let n = selected.count
        importButton.setTitle(n == 0 ? "导入选中" : "导入选中 (\(n))", for: .normal)
        importButton.alpha = n == 0 ? 0.45 : 1.0
        importButton.isEnabled = n > 0
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 必须用 .subtitle 样式，register(class:) 默认只有 textLabel
        let cell = tableView.dequeueReusableCell(withIdentifier: "ScriptFileCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "ScriptFileCell")
        let it = items[indexPath.row]
        cell.textLabel?.text = it.name
        cell.textLabel?.textColor = Theme.text
        var parts = [Self.sizeText(it.size)]
        if let d = it.modified {
            parts.append(Self.dateFormatter.string(from: d))
        }
        cell.detailTextLabel?.text = parts.joined(separator: " · ")
        cell.detailTextLabel?.textColor = Theme.subtext
        cell.backgroundColor = Theme.cardBg
        cell.accessoryType = selected.contains(indexPath.row) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let it = items[indexPath.row]

        // 单选回调模式：回填给调用方后返回
        if let pick = onPick {
            pick(it.url, it.name)
            navigationController?.popViewController(animated: true)
            return
        }

        if selected.contains(indexPath.row) { selected.remove(indexPath.row) }
        else { selected.insert(indexPath.row) }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateImportButton()
    }

    // MARK: - 导入

    @objc private func importTapped() {
        let picked = selected.sorted().map { items[$0] }
        guard !picked.isEmpty else { return }

        importButton.isEnabled = false
        importButton.setTitle("导入中…", for: .normal)
        importSucceed = []
        importFailed = []
        importNext(picked)
    }

    /// 串行导入：LX 脚本若走异步 inited（最多 3.2s 后才回调），必须等回调到了再处理下一个，
    /// 否则会把「异步成功」误判成失败 —— 所以这里不能在主线程上用 semaphore 硬等。
    private func importNext(_ queue: [Item]) {
        guard let it = queue.first else {
            finishImport()
            return
        }
        let rest = Array(queue.dropFirst())

        guard let code = Self.readText(it.url),
              code.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            importFailed.append("\(it.name)：读不出来（非文本或编码不支持）")
            importNext(rest)
            return
        }

        let id = Self.makeID(from: it.name)
        switch mode {
        case .builtinScript:
            if ScriptManager.shared.saveCustomScript(id: id, name: it.name, code: code) {
                importSucceed.append((it.name, []))
            } else {
                importFailed.append("\(it.name)：保存失败")
            }
            importNext(rest)

        case .lxScript:
            LXCompatEngine.shared.importUserScript(id: id, displayName: it.name, rawCode: code) { [weak self] ok, plats in
                guard let self = self else { return }
                if ok {
                    self.importSucceed.append((it.name, plats))
                } else {
                    self.importFailed.append("\(it.name)：未声明平台（缺少 lx.send('inited')）")
                }
                self.importNext(rest)
            }
        }
    }

    private func finishImport() {
        let modeName = (mode == .lxScript) ? "洛雪" : "自定义"
        Logger.info("本地脚本导入：成功 \(importSucceed.count) 个，失败 \(importFailed.count) 个（模式=\(modeName)）")

        var message = ""
        if !importSucceed.isEmpty {
            message += "已导入：\n" + importSucceed.map { item -> String in
                item.platforms.isEmpty ? "· \(item.name)" : "· \(item.name)（\(item.platforms.joined(separator: "/"))）"
            }.joined(separator: "\n")
        }
        if !importFailed.isEmpty {
            message += (message.isEmpty ? "" : "\n\n") + "失败：\n" + importFailed.map { "· \($0)" }.joined(separator: "\n")
        }

        let alert = UIAlertController(
            title: importFailed.isEmpty ? "导入完成" : "导入完成（有失败）",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        importButton.setTitle("导入选中", for: .normal)
        updateImportButton()
        present(alert, animated: true)
    }
}
