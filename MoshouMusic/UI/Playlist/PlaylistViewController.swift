import UIKit
import UniformTypeIdentifiers

/// 歌单页 — 我的列表管理
class PlaylistViewController: UIViewController {

    private let tableView = UITableView()
    private let emptyLabel = UILabel()
    private let fabButton = UIButton(type: .system)

    private var playlists: [Playlist] = []

    /// FAB 距底部距离，播放条显示时单独抬升（不动页面整体布局）
    /// 闲置：safeArea.bottom - 20
    /// 播放：safeArea.bottom - 20 - 64 = safeArea.bottom - 84
    private var fabBottomConstraint: NSLayoutConstraint!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadPlaylists()

        // 按当前状态初始化 FAB 位置（防止播放中首次进入时被遮挡）
        applyMiniPlayerAdjustment(visible: PlayerManager.shared.currentSong != nil)

        // 监听播放条可见性变化，单独上移 FAB（不动页面整体）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(miniPlayerVisibilityChanged(_:)),
            name: .miniPlayerVisibilityChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadPlaylists()
        // 页面每次回到前台再校准一次（处理其他页面播放过再切回）
        applyMiniPlayerAdjustment(visible: PlayerManager.shared.currentSong != nil)
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "我的"

        // 表格
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PlaylistCell.self, forCellReuseIdentifier: PlaylistCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 80
        tableView.rowHeight = UITableView.automaticDimension
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0)
        view.addSubview(tableView)

        // 空状态
        emptyLabel.text = "还没有歌单\n点击右下角新建"
        emptyLabel.font = Theme.bodyLarge
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        // FAB
        fabButton.setImage(
            UIImage(systemName: "plus")?
                .withTintColor(.white, renderingMode: .alwaysOriginal),
            for: .normal
        )
        fabButton.backgroundColor = Theme.primary
        fabButton.layer.cornerRadius = 28
        fabButton.layer.shadowColor = Theme.primary.cgColor
        fabButton.layer.shadowOpacity = 0.3
        fabButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        fabButton.layer.shadowRadius = 8
        fabButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
        view.addSubview(fabButton)

        setupConstraints()

        // 导入歌单按钮
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "导入",
            style: .plain,
            target: self,
            action: #selector(importTapped)
        )

        // 监听歌单变化
        NotificationCenter.default.addObserver(
            self, selector: #selector(playlistsChanged),
            name: PlaylistStore.didChangeNotification, object: nil
        )
    }

    private func setupConstraints() {
        [tableView, emptyLabel, fabButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // FAB 的 bottom 约束做成可变的，便于后续通知驱动单独抬升
        fabBottomConstraint = fabButton.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20
        )

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            fabButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fabBottomConstraint,
            fabButton.widthAnchor.constraint(equalToConstant: 56),
            fabButton.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    // MARK: - FAB 让位逻辑

    /// 单独让 FAB 上移避让播放条，不动页面整体布局
    /// - 闲置时 FAB 距 safeArea 底部 20pt；播放时再多抬 64pt = 84pt
    /// - 同步调整 tableView.contentInset 避免最后一行被抬起的 FAB 遮住
    @objc private func miniPlayerVisibilityChanged(_ note: Notification) {
        let visible = (note.userInfo?["visible"] as? Bool) ?? false
        applyMiniPlayerAdjustment(visible: visible)
    }

    private func applyMiniPlayerAdjustment(visible: Bool) {
        // FAB 离底部距离：闲置 20pt，播放 20 + 64 = 84pt
        let fabBottom: CGFloat = visible ? -84 : -20
        // 列表底部 inset：保留 FAB 56 + 间距(16) ≈ 80pt；播放时再多 64pt
        let tableBottom: CGFloat = visible ? 144 : 80

        if fabBottomConstraint.constant != fabBottom {
            fabBottomConstraint.constant = fabBottom
        }
        if tableView.contentInset.bottom != tableBottom {
            tableView.contentInset.bottom = tableBottom
            tableView.verticalScrollIndicatorInsets.bottom = tableBottom
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - 数据

    private func loadPlaylists() {
        playlists = PlaylistStore.shared.playlists
        tableView.reloadData()
        emptyLabel.isHidden = !playlists.isEmpty
    }

    @objc private func playlistsChanged() {
        loadPlaylists()
    }

    // MARK: - 新建

    @objc private func createTapped() {
        let alert = UIAlertController(title: "新建歌单", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "歌单名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            if let name = alert.textFields?.first?.text, !name.isEmpty {
                PlaylistStore.shared.create(name: name)
            }
        })
        present(alert, animated: true)
    }

    // MARK: - 导入分享链接

    @objc private func importTapped() {
        let alert = UIAlertController(
            title: "导入歌单",
            message: "选择导入方式",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "从分享链接导入", style: .default) { [weak self] _ in
            self?.presentLinkImport()
        })
        alert.addAction(UIAlertAction(title: "从文件导入 (.lxmc/.json)", style: .default) { [weak self] _ in
            self?.presentImportFilePicker()
        })
        alert.addAction(UIAlertAction(title: "粘贴 JSON 文本", style: .default) { [weak self] _ in
            self?.presentPasteJSON()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }

    /// 链接导入弹窗
    private func presentLinkImport() {
        let alert = UIAlertController(
            title: "从分享链接导入",
            message: "粘贴网易云 / QQ音乐 / 酷狗的分享链接，自动匹配本机音源后加入歌单",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "https://..."
            tf.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let link = alert.textFields?.first?.text ?? ""
            guard !link.isEmpty else { return }
            self.runImport(link: link)
        })
        present(alert, animated: true)
    }

    /// 文件导入：LX 桌面版导出 .lxmc（gzip JSON）或 .json
    private func presentImportFilePicker() {
        var types: [UTType] = [.json, .plainText, .data]
        if let lxmc = UTType(filenameExtension: "lxmc") { types.append(lxmc) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)

        // TrollStore 沙盒下文档选择器常无回调，加超时兜底提示
        importPickerTimeout?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.showAlert(title: "文件导入可能不可用",
                            message: "在 TrollStore 环境下系统文件选择器偶尔选不到文件。可改用「粘贴 JSON 文本」，或在 Files / 分享菜单里用「墨守music」打开 .lxmc 文件。")
        }
        importPickerTimeout = timer
    }

    private var importPickerTimeout: Timer?

    /// 粘贴 JSON 文本（.lxmc 需先解压为 JSON 再粘贴）
    private func presentPasteJSON() {
        let alert = UIAlertController(title: "粘贴歌单 JSON", message: "把 LX 导出文件的 JSON 内容粘贴到此处", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "粘贴 JSON…"
            tf.keyboardType = .default
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            guard let self = self else { return }
            guard let text = alert.textFields?.first?.text, !text.isEmpty,
                  let data = text.data(using: .utf8) else { return }
            self.importLXData(data)
        })
        present(alert, animated: true)
    }

    /// 解析 LX 文件数据并写入本地歌单
    func importLXData(_ data: Data) {
        do {
            let lists = try LXPlaylistBridge.parseLXMC(data: data)
            let (pls, songs) = LXPlaylistBridge.importParsed(lists)
            showAlert(title: "导入成功",
                      message: "共导入 \(pls) 个歌单，\(songs) 首歌曲")
        } catch {
            showAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func runImport(link: String) {
        let progressAlert = UIAlertController(title: "正在导入…", message: "准备中", preferredStyle: .alert)
        present(progressAlert, animated: true)

        PlaylistImporter.shared.importFromLink(link: link, progress: { [weak progressAlert] p in
            progressAlert?.message = "\(p.stage)\n已匹配 \(p.matched)/\(p.total)"
        }) { [weak self] result in
            progressAlert.dismiss(animated: true) {
                guard let self = self else { return }
                switch result {
                case .failure(let e):
                    self.showImportResult(title: "导入失败", message: e.localizedDescription)
                case .success(let r):
                    var msg = "平台：\(r.platform)\n共 \(r.total) 首，成功匹配 \(r.matched) 首"
                    if !r.skipped.isEmpty {
                        let names = r.skipped.prefix(5).map { "· \($0.name) - \($0.artist)" }.joined(separator: "\n")
                        msg += "\n\n未找到可播放版本（\(r.skipped.count) 首）：\n\(names)"
                        if r.skipped.count > 5 { msg += "\n…" }
                    }
                    self.showImportResult(title: "已导入「\(r.playlistName)」", message: msg)
                }
            }
        }
    }

    private func showImportResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 文件导入代理

extension PlaylistViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
        guard let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            importLXData(data)
        } catch {
            showAlert(title: "读取文件失败", message: error.localizedDescription)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importPickerTimeout?.invalidate()
        importPickerTimeout = nil
    }
}

// MARK: - UITableViewDataSource & Delegate

extension PlaylistViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return playlists.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistCell.reuseIdentifier, for: indexPath) as! PlaylistCell
        cell.configure(with: playlists[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let playlist = playlists[indexPath.row]
        let detailVC = PlaylistDetailViewController(playlist: playlist)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { _, _, completion in
            let playlist = self.playlists[indexPath.row]
            PlaylistStore.shared.delete(id: playlist.id)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - PlaylistCell

class PlaylistCell: UITableViewCell {

    static let reuseIdentifier = "PlaylistCell"

    private let containerView = UIView()
    private let iconView = UIView()
    private let iconImage = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

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
        backgroundColor = .clear

        containerView.backgroundColor = Theme.cardBg
        containerView.layer.cornerRadius = Theme.cornerMedium
        contentView.addSubview(containerView)

        iconView.backgroundColor = Theme.primaryContainer
        iconView.layer.cornerRadius = 12
        containerView.addSubview(iconView)

        iconImage.image = UIImage(systemName: "music.note")?
            .withTintColor(Theme.primary, renderingMode: .alwaysOriginal)
        iconImage.contentMode = .scaleAspectFit
        iconView.addSubview(iconImage)

        nameLabel.font = Theme.titleSmall
        nameLabel.textColor = Theme.text
        containerView.addSubview(nameLabel)

        countLabel.font = Theme.bodySmall
        countLabel.textColor = Theme.subtext
        containerView.addSubview(countLabel)

        [containerView, iconView, iconImage, nameLabel, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            iconView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            iconImage.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconImage.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            iconImage.widthAnchor.constraint(equalToConstant: 24),
            iconImage.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),

            countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with playlist: Playlist) {
        nameLabel.text = playlist.name
        countLabel.text = "\(playlist.songs.count) 首"
    }
}

// MARK: - PlaylistDetailViewController

class PlaylistDetailViewController: UIViewController {

    private var playlist: Playlist
    private let tableView = UITableView()

    init(playlist: Playlist) {
        self.playlist = playlist
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = playlist.name
        view.backgroundColor = Theme.bg

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongCell.self, forCellReuseIdentifier: SongCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // F5: 在线导入且保留链接的歌单，提供「更新歌单」按钮
        if !playlist.sourceListId.isEmpty, playlist.location == "online" {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "更新歌单", style: .plain, target: self, action: #selector(updateTapped)
            )
        }

        // 歌单被更新（replaceSongs）后刷新本页
        NotificationCenter.default.addObserver(
            self, selector: #selector(playlistStoreChanged),
            name: PlaylistStore.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playlistStoreChanged() {
        if let updated = PlaylistStore.shared.get(id: playlist.id) {
            playlist = updated
            title = playlist.name
            tableView.reloadData()
        }
    }

    // MARK: - 更新歌单

    @objc private func updateTapped() {
        let alert = UIAlertController(title: "正在更新歌单…", message: "准备中", preferredStyle: .alert)
        present(alert, animated: true)

        PlaylistImporter.shared.updatePlaylist(playlistId: playlist.id, progress: { [weak alert] p in
            alert?.message = "\(p.stage)\n已匹配 \(p.matched)/\(p.total)"
        }) { [weak self] result in
            alert.dismiss(animated: true) {
                guard let self = self else { return }
                switch result {
                case .failure(let e):
                    self.showDetailResult(title: "更新失败", message: e.localizedDescription)
                case .success(let r):
                    var msg = "更新完成\n平台：\(r.platform)\n共 \(r.total) 首，成功匹配 \(r.matched) 首"
                    if !r.skipped.isEmpty {
                        let names = r.skipped.prefix(5).map { "· \($0.name) - \($0.artist)" }.joined(separator: "\n")
                        msg += "\n\n未找到可播放版本（\(r.skipped.count) 首）：\n\(names)"
                        if r.skipped.count > 5 { msg += "\n…" }
                    }
                    self.showDetailResult(title: "已更新「\(r.playlistName)」", message: msg)
                }
            }
        }
    }

    private func showDetailResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}

extension PlaylistDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return playlist.songs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SongCell.reuseIdentifier, for: indexPath) as! SongCell
        cell.configure(with: playlist.songs[indexPath.row], index: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        PlayerManager.shared.playAll(playlist.songs, from: indexPath.row)
    }
}
