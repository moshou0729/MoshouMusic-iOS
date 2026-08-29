import UIKit
import UniformTypeIdentifiers

/// LX Music 桌面版同步设置页
/// v1.0.17 修复：4 张卡片改用 UIStackView 堆叠（修复所有卡片全叠顶部看不见 URL 输入的 bug）
/// v1.0.18+ 将基于 LX 桌面版 WebSocket RPC（message2call）实现完整双向同步
class LXSyncViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let containerStack = UIStackView()

    private let urlField = UITextField()
    private let statusBadge = UILabel()
    private let detailLabel = UILabel()
    private let testButton = UIButton(type: .system)
    private let enableSwitch = UISwitch()
    private let saveButton = UIButton(type: .system)
    private let resultLabel = UILabel()
    private var importPickerTimeout: Timer?

    // 开始同步（Phase 2 实时双向）
    private let codeField = UITextField()
    private let modeSegment = UISegmentedControl(items: ["合并(推荐)", "以桌面为准", "以手机为准"])
    private let startSyncButton = UIButton(type: .system)
    private let stopSyncButton = UIButton(type: .system)
    private let syncStatusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "LX 数据同步"
        view.backgroundColor = Theme.bg

        setupUI()
        refreshStatus(LXSyncService.shared.status)
        urlField.text = ConfigStore.shared.lxSyncServerURL
        enableSwitch.isOn = ConfigStore.shared.lxSyncEnabled

        NotificationCenter.default.addObserver(
            self, selector: #selector(lxStateChanged),
            name: LXSyncService.stateChangedNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag

        // 一个 vertical stack 装所有卡片 — 自动按顺序堆叠，不会再叠在一起
        containerStack.axis = .vertical
        containerStack.spacing = 16
        containerStack.alignment = .fill
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(containerStack)

        // ===== 卡片 1：URL 输入（首屏第一张，可见） =====
        let urlCard = makeCard(
            title: "同步服务地址",
            subtitle: "LX 桌面版 v2.4+ / 独立版 sync-server v2.0+"
        )
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "http://192.168.1.5:23332"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .done
        urlField.font = Theme.bodyMedium
        urlField.delegate = self
        urlCard.stack.addArrangedSubview(urlField)
        urlField.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let urlHint = UILabel()
        urlHint.text = "桌面端：「设置 → 数据同步 → 服务端模式」；URL 在桌面版同步设置里显示。"
        urlHint.font = Theme.bodySmall
        urlHint.textColor = Theme.subtext
        urlHint.numberOfLines = 0
        urlCard.stack.addArrangedSubview(urlHint)

        saveButton.setTitle("保存地址", for: .normal)
        saveButton.titleLabel?.font = Theme.titleSmall
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = Theme.success
        saveButton.layer.cornerRadius = Theme.cornerMedium
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        urlCard.stack.addArrangedSubview(saveButton)
        saveButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        urlCard.add(to: containerStack)

        // ===== 卡片 2：连接状态 + 测试按钮 =====
        let statusCard = makeCard(title: "连接状态", subtitle: nil)

        statusBadge.font = .systemFont(ofSize: 16, weight: .semibold)
        statusBadge.numberOfLines = 0
        statusCard.stack.addArrangedSubview(statusBadge)

        detailLabel.font = Theme.bodySmall
        detailLabel.textColor = Theme.subtext
        detailLabel.numberOfLines = 0
        statusCard.stack.addArrangedSubview(detailLabel)

        testButton.setTitle("测试连接", for: .normal)
        testButton.titleLabel?.font = Theme.titleSmall
        testButton.setTitleColor(.white, for: .normal)
        testButton.backgroundColor = Theme.primary
        testButton.layer.cornerRadius = Theme.cornerMedium
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        statusCard.stack.addArrangedSubview(testButton)
        testButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        statusCard.add(to: containerStack)

        // ===== 卡片 3：启用同步 =====
        let enableCard = makeCard(title: "启用同步", subtitle: nil)

        let enableRow = UIStackView()
        enableRow.axis = .horizontal
        enableRow.alignment = .center
        enableRow.spacing = 12

        let enableLabel = UILabel()
        enableLabel.text = "启动时尝试与上述服务器建立连接"
        enableLabel.font = Theme.bodyMedium
        enableLabel.textColor = Theme.text
        enableLabel.numberOfLines = 0
        enableRow.addArrangedSubview(enableLabel)

        enableSwitch.onTintColor = Theme.primary
        enableSwitch.addTarget(self, action: #selector(enableChanged), for: .valueChanged)
        enableSwitch.setContentHuggingPriority(.required, for: .horizontal)
        enableSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        enableRow.addArrangedSubview(enableSwitch)

        enableCard.stack.addArrangedSubview(enableRow)
        enableCard.add(to: containerStack)

        // ===== 卡片 3.5：开始同步（Phase 2 实时双向） =====
        let syncCard = makeCard(title: "开始同步（实时双向）",
                               subtitle: "输入桌面端「同步设置 → 服务端模式」里显示的 6 位同步码")
        codeField.borderStyle = .roundedRect
        codeField.placeholder = "6 位同步码"
        codeField.keyboardType = .numberPad
        codeField.delegate = self
        codeField.font = Theme.bodyMedium
        codeField.heightAnchor.constraint(equalToConstant: 44).isActive = true
        syncCard.stack.addArrangedSubview(codeField)

        let modeHint = UILabel()
        modeHint.text = "手机端建议的合并策略（最终由桌面端连接时确认）："
        modeHint.font = Theme.bodySmall
        modeHint.textColor = Theme.subtext
        modeHint.numberOfLines = 0
        syncCard.stack.addArrangedSubview(modeHint)

        let mode = ConfigStore.shared.lxSyncMode
        switch mode {
        case "overwrite_remote_local": modeSegment.selectedSegmentIndex = 1
        case "overwrite_local_remote": modeSegment.selectedSegmentIndex = 2
        default:                       modeSegment.selectedSegmentIndex = 0
        }
        modeSegment.selectedSegmentTintColor = Theme.primary
        modeSegment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        syncCard.stack.addArrangedSubview(modeSegment)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        startSyncButton.setTitle("开始同步", for: .normal)
        startSyncButton.setTitleColor(.white, for: .normal)
        startSyncButton.backgroundColor = Theme.primary
        startSyncButton.layer.cornerRadius = Theme.cornerMedium
        startSyncButton.titleLabel?.font = Theme.titleSmall
        startSyncButton.addTarget(self, action: #selector(startSyncTapped), for: .touchUpInside)
        startSyncButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stopSyncButton.setTitle("断开", for: .normal)
        stopSyncButton.setTitleColor(.white, for: .normal)
        stopSyncButton.backgroundColor = Theme.secondary
        stopSyncButton.layer.cornerRadius = Theme.cornerMedium
        stopSyncButton.titleLabel?.font = Theme.titleSmall
        stopSyncButton.addTarget(self, action: #selector(stopSyncTapped), for: .touchUpInside)
        stopSyncButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(startSyncButton)
        row.addArrangedSubview(stopSyncButton)
        syncCard.stack.addArrangedSubview(row)

        let diagButton = makeButton("诊断 /ah 连通性", color: Theme.warning)
        diagButton.addTarget(self, action: #selector(diagTapped), for: .touchUpInside)
        syncCard.stack.addArrangedSubview(diagButton)
        diagButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        syncStatusLabel.font = Theme.bodyMedium
        syncStatusLabel.textColor = Theme.text
        syncStatusLabel.numberOfLines = 0
        syncCard.stack.addArrangedSubview(syncStatusLabel)

        syncCard.add(to: containerStack)

        // ===== 卡片 4：使用说明（页底，可滚动查看） =====
        let helpCard = makeCard(title: "关于本功能", subtitle: nil)
        let helpText = UILabel()
        helpText.font = Theme.bodySmall
        helpText.textColor = Theme.subtext
        helpText.numberOfLines = 0
        helpText.text = """
        当前版本已支持 LX 桌面版原生 WebSocket 实时双向同步（message2call RPC 协议），可同步「收藏歌单」与「我喜欢」。

        使用步骤：
        1. 桌面端「设置 → 同步 → 开启服务端模式」，记下 6 位同步码
        2. 上方填写桌面端显示的地址（如 http://192.168.x.x:23332）
        3. 输入 6 位同步码，点「开始同步」
        4. 桌面端弹出合并/覆盖选择，确认后即双向同步

        同步模式说明：
        · 合并（推荐）：手机与桌面数据合并
        · 以桌面为准：用桌面数据覆盖手机
        · 以手机为准：用手机数据覆盖桌面

        提示：协议传输的数据为明文，请仅在受信任的局域网内使用（官方文档原话）。
        """
        helpCard.stack.addArrangedSubview(helpText)
        helpCard.add(to: containerStack)

        // ===== 卡片 5：歌单文件互导 (Phase 1) =====
        let bridgeCard = makeCard(title: "歌单文件互导（Phase 1）", subtitle: "无需实时连接，手动与 LX 桌面版互导歌单")
        let bridgeDesc = UILabel()
        bridgeDesc.font = Theme.bodySmall
        bridgeDesc.textColor = Theme.subtext
        bridgeDesc.numberOfLines = 0
        bridgeDesc.text = "导入：把 LX 桌面版「导出」的歌单 JSON 导入到本机。\n导出：把本机歌单导出为 LX 兼容 JSON（可再导回本 App；导入 LX 桌面版为尽力而为）。"
        bridgeCard.stack.addArrangedSubview(bridgeDesc)

        let importBtn = makeButton("从 LX 导出文件导入", color: Theme.primary)
        importBtn.addTarget(self, action: #selector(importFromFileTapped), for: .touchUpInside)
        bridgeCard.stack.addArrangedSubview(importBtn)
        importBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let importDocsBtn = makeButton("导入 Documents/lx-playlist.json", color: Theme.secondary)
        importDocsBtn.addTarget(self, action: #selector(importFromDocsTapped), for: .touchUpInside)
        bridgeCard.stack.addArrangedSubview(importDocsBtn)
        importDocsBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let exportBtn = makeButton("导出我的歌单为 JSON", color: Theme.tertiary)
        exportBtn.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        bridgeCard.stack.addArrangedSubview(exportBtn)
        exportBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true

        resultLabel.font = Theme.bodyMedium
        resultLabel.textColor = Theme.text
        resultLabel.numberOfLines = 0
        bridgeCard.stack.addArrangedSubview(resultLabel)

        bridgeCard.add(to: containerStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            containerStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            containerStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            containerStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            containerStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            containerStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存", style: .done, target: self, action: #selector(saveTapped)
        )
    }

    @objc private func lxStateChanged() {
        refreshStatus(LXSyncService.shared.status)
    }

    private func refreshStatus(_ status: LXSyncService.Status) {
        statusBadge.text = status.displayText.split(separator: "\n").first.map(String.init) ?? ""
        let color: UIColor
        let detail: String
        switch status {
        case .notConfigured:
            color = Theme.subtext
            detail = "请填写上方同步服务地址后点「保存地址」"
        case .idle:
            color = Theme.subtext
            detail = "点「测试连接」可立即验证网络可达性"
        case .testing:
            color = Theme.warning
            detail = "向 /hello 发起 HTTP 请求，最多 25 秒超时"
        case .ok(let h, _):
            color = Theme.success
            let parts = h.split(separator: "\n").map(String.init)
            detail = "握手成功，服务器标识：\n" + (parts.last ?? h)
        case .connecting:
            color = Theme.warning
            detail = "正在与桌面端完成认证（/id、RSA 密钥交换、/ah）"
        case .syncing:
            color = Theme.warning
            detail = "WebSocket 已连接，桌面端正在编排歌单同步"
        case .synced(let n):
            color = Theme.success
            let date = ConfigStore.shared.lxLastSyncDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
            } ?? ""
            detail = "歌单已同步，当前共 \(n) 个歌单" + (date.isEmpty ? "" : "（\(date)）")
        case .failed(let r):
            color = Theme.error
            detail = r
        case .disconnected:
            color = Theme.subtext
            detail = "连接已断开（已同步的数据已保留在本机）"
        }
        statusBadge.textColor = color
        detailLabel.text = detail
        // 拼接当前阶段文字（service 在 .connecting / .syncing 期间会更新 currentStep，
        // 让用户清楚看到正在 /ah 认证 / 拉歌单，而不是「一闪而过就变 ✗」以为没反应）
        let main = status.displayText
        if let step = LXSyncService.shared.currentStep, !step.isEmpty {
            syncStatusLabel.text = "\(main)\n⏳ \(step)"
        } else {
            syncStatusLabel.text = main
        }
        syncStatusLabel.textColor = color
    }

    @objc private func testTapped() {
        let text = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.shared.lxSyncServerURL = text
        ConfigStore.shared.save()
        LXSyncService.shared.refreshInitialState()
        LXSyncService.shared.testConnection()
        showToast("已发起测试…")
    }

    @objc private func saveTapped() {
        let text = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ConfigStore.shared.lxSyncServerURL = text
        ConfigStore.shared.save()
        LXSyncService.shared.refreshInitialState()
        showToast("已保存")
    }

    @objc private func enableChanged() {
        ConfigStore.shared.lxSyncEnabled = enableSwitch.isOn
        ConfigStore.shared.save()
    }

    @objc private func startSyncTapped() {
        codeField.resignFirstResponder()
        let code = (codeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: code)) else {
            showToast("请输入 6 位数字同步码")
            return
        }
        LXSyncService.shared.startSync(authCode: code)
        showToast("正在连接桌面端…")
    }

    @objc private func stopSyncTapped() {
        LXSyncService.shared.stopSync()
        showToast("已断开连接")
    }

    @objc private func diagTapped() {
        let code = (codeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        syncStatusLabel.text = "正在用同步码做真实 /ah 认证…（最多 20 秒）"
        syncStatusLabel.textColor = Theme.warning
        LXSyncService.shared.probeAH(authCode: code) { [weak self] result in
            DispatchQueue.main.async {
                self?.syncStatusLabel.text = result
            }
        }
    }

    @objc private func modeChanged() {
        let mode: String
        switch modeSegment.selectedSegmentIndex {
        case 1: mode = "overwrite_remote_local"
        case 2: mode = "overwrite_local_remote"
        default: mode = "merge_local_remote"
        }
        ConfigStore.shared.lxSyncMode = mode
        ConfigStore.shared.save()
    }

    private func showToast(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            alert.dismiss(animated: true)
        }
    }

    // MARK: - 歌单文件互导 (Phase 1)

    @objc private func importFromFileTapped() {
        // 用 .item 兜底，TrollStore 沙盒下才能列出 .lxmc / .json 等任意文件
        var types: [UTType] = [.item]
        if let lxmc = UTType(filenameExtension: "lxmc") { types.append(lxmc) }
        types.append(.json)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)

        // TrollStore 沙盒下文档选择器常无回调，加超时兜底提示（含导入/导出操作说明）
        importPickerTimeout?.invalidate()
        importPickerTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.resultLabel.text = "提示：若文件选择器选不到 .lxmc / .json，可改用「导入 Documents/lx-playlist.json」：把 LX 桌面版导出的文件用 Filza/Files 放进 App 沙盒 Documents 目录后点此按钮。\n\n导入/导出说明：\n· 导出：点「导出我的歌单为 JSON」→ 用分享面板存到 Files / AirDrop（文件名 MoshouMusic-lx-export.json）。\n· 导入：本机文件用上方选择器选 .lxmc（LX 数据备份，gzip 压缩）或 .json；或把文件命名为 lx-playlist.json 放进 Documents 后点「导入 Documents/lx-playlist.json」。"
        }
    }

    @objc private func importFromDocsTapped() {
        let url = ConfigStore.shared.documentsDirectory.appendingPathComponent("lx-playlist.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            resultLabel.text = "未在 Documents 找到 lx-playlist.json。请把 LX 导出的歌单 JSON 命名为 lx-playlist.json 放进 App 沙盒 Documents 目录（可用 Filza）。"
            return
        }
        doImport(at: url)
    }

    private func doImport(at url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            resultLabel.text = "读取文件失败"
            return
        }
        do {
            // parseLXMC 会先嗅探 gzip 魔数（.lxmc 为 gzip 压缩 JSON），再走通用解析，
            // 因此 .lxmc 与 .json 都能正确导入
            let imports = try LXPlaylistBridge.parseLXMC(data: data)
            var totalPlaylists = 0, totalSongs = 0
            for imp in imports {
                let added = PlaylistStore.shared.mergeSongs(imp.songs, intoPlaylistNamed: imp.name)
                totalPlaylists += 1
                totalSongs += added
            }
            resultLabel.text = "导入成功：歌单 \(totalPlaylists) 个，新增歌曲 \(totalSongs) 首。"
            NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: nil)
        } catch {
            resultLabel.text = "导入失败：\(error.localizedDescription)"
        }
    }

    @objc private func exportTapped() {
        let playlists = PlaylistStore.shared.playlists
        let data = LXPlaylistBridge.encode(playlists: playlists)
        let url = ConfigStore.shared.documentsDirectory.appendingPathComponent("MoshouMusic-lx-export.json")
        do {
            try data.write(to: url, options: .atomic)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            av.completionWithItemsHandler = { [weak self] _, _, _, _ in
                self?.resultLabel.text = "已导出到：\(url.lastPathComponent)\n可用「分享」存到 Files / AirDrop，或再导回本 App。"
            }
            present(av, animated: true)
        } catch {
            resultLabel.text = "导出失败：\(error.localizedDescription)"
        }
    }

    private func makeButton(_ title: String, color: UIColor) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Theme.titleSmall
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = color
        b.layer.cornerRadius = Theme.cornerMedium
        return b
    }

    // MARK: - 卡片构建

    private func makeCard(title: String, subtitle: String?) -> Card {
        return Card(title: title, subtitle: subtitle)
    }

    private final class Card {
        let view: UIView
        let stack: UIStackView

        init(title: String, subtitle: String?) {
            let container = UIView()
            container.backgroundColor = Theme.cardBg
            container.layer.cornerRadius = Theme.cornerMedium
            container.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = UILabel()
            titleLabel.font = Theme.titleSmall
            titleLabel.textColor = Theme.text
            titleLabel.text = title
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let subtitleLabel = UILabel()
            subtitleLabel.font = Theme.bodySmall
            subtitleLabel.textColor = Theme.subtext
            subtitleLabel.text = subtitle
            subtitleLabel.numberOfLines = 0
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.isHidden = (subtitle == nil || subtitle!.isEmpty)

            let inner = UIStackView()
            inner.axis = .vertical
            inner.spacing = 12
            inner.alignment = .fill
            inner.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(titleLabel)
            container.addSubview(subtitleLabel)
            container.addSubview(inner)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

                inner.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: subtitleLabel.isHidden ? 0 : 12),
                inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            ])

            self.view = container
            self.stack = inner
        }

        /// 把卡片 view 加入任何 vertical stack — 由 stack 自动堆叠，不再发生"全叠顶部"的 bug
        func add(to parentStack: UIStackView) {
            parentStack.addArrangedSubview(view)
        }
    }
}

extension LXSyncViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension LXSyncViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
        guard let url = urls.first else { return }
        doImport(at: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
    }
}
