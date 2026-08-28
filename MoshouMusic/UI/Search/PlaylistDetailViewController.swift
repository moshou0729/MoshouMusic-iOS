import UIKit

/// 歌单详情页 — 从搜索页「歌单」模式点歌单 push 进来
///
/// 设计目标（v1.0.38 P2）：
/// - 进入页面立即调 `PlaylistImporter.previewTracks` 拉取曲目列表（仅展示，不立即匹配）
/// - 列表显示当前所有曲目（用户决定是否要导入/播放）
/// - 底部三个动作：
///   ①「立即全部播放」：把当前曲目按"原平台 → 本机已启用源"找可播放版本（用 SourceSwitcher.findSong）
///      找到第一首就立即开播，后续找到的后续追加到队列尾部
///   ②「加入播放队列」：同上但不开播，把所有匹配到的加入队列尾部
///   ③「收藏到本地」：触发后台导入，不阻塞 UI；关闭详情页后由全局 banner 跟进
///
/// 优化点（相对 v1.0.36）：
/// - 进入页面立刻看曲目列表，不需要等匹配 / 导入
/// - 头部展示曲目数 + 平台来源，没有"未知/解析中"全屏遮罩
/// - 后台导入不再"全屏遮罩卡片+永不消失"——已发现的卡死问题不再可能发生
class SearchedPlaylistDetailViewController: UIViewController {

    // MARK: - Data

    private let searchedPlaylist: SearchedPlaylist
    /// 完整 Track 列表（已从原平台拉取完成）
    private var tracks: [PlaylistImporter.Track] = []
    private var playlistName: String = ""
    private var isLoading = true
    private var loadError: String?

    // MARK: - UI

    private let headerView = UIView()
    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let trackCountLabel = UILabel()
    private let segmented = UISegmentedControl(items: ["全部", "可播", "无匹配"])

    private let tableView = UITableView()
    private let footerContainer = UIView()
    private let playAllButton = UIButton(type: .system)
    private let addQueueButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    private enum FilterMode: Int { case all = 0, playable = 1, unmatched = 2 }
    private var currentFilter: FilterMode = .all

    /// 当前已"信号化"哪些 Track 是可播的（局部预检）—— 真正的源解析留给「立即播放」时
    private var trackPlayability: [Bool] = []
    /// 已经在后台尝试过"预检匹配"的 Track 数量（用来逐步增加数字）

    // MARK: - Init

    init(searchedPlaylist pl: SearchedPlaylist) {
        self.searchedPlaylist = pl
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        title = "歌单详情"
        navigationItem.largeTitleDisplayMode = .never

        setupHeader()
        setupTable()
        setupFooter()
        setupSegmented()
        loadTracks()
    }

    // MARK: - UI

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.layer.cornerRadius = 10
        artworkView.clipsToBounds = true
        artworkView.contentMode = .scaleAspectFill
        artworkView.backgroundColor = Theme.cardBg
        headerView.addSubview(artworkView)

        titleLabel.font = Theme.titleLarge
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel.font = Theme.bodyMedium
        subtitleLabel.textColor = Theme.subtext
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        trackCountLabel.font = Theme.bodySmall
        trackCountLabel.textColor = Theme.subtext
        trackCountLabel.numberOfLines = 0
        trackCountLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(trackCountLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            artworkView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            artworkView.topAnchor.constraint(equalTo: headerView.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 100),
            artworkView.heightAnchor.constraint(equalToConstant: 100),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            trackCountLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            trackCountLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            trackCountLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
            trackCountLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerView.bottomAnchor),
        ])

        artworkView.layer.shadowColor = UIColor.black.cgColor
        artworkView.layer.shadowOpacity = 0.1
        artworkView.layer.shadowOffset = CGSize(width: 0, height: 2)
        artworkView.layer.shadowRadius = 6
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PlaylistTrackCell.self, forCellReuseIdentifier: PlaylistTrackCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.rowHeight = 64
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = Theme.outlineVariant
        tableView.allowsMultipleSelectionDuringEditing = false
        view.addSubview(tableView)
    }

    private func setupSegmented() {
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegmentIndex = 0
        segmented.selectedSegmentTintColor = Theme.primary
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segmented.setTitleTextAttributes([.foregroundColor: Theme.primary], for: .normal)
        segmented.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        view.addSubview(segmented)
    }

    private func setupFooter() {
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.backgroundColor = Theme.cardBg
        view.addSubview(footerContainer)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        footerContainer.addSubview(stack)

        playAllButton.setTitle("全部播放", for: .normal)
        playAllButton.setTitleColor(.white, for: .normal)
        playAllButton.backgroundColor = Theme.primary
        playAllButton.titleLabel?.font = Theme.labelLarge
        playAllButton.layer.cornerRadius = 10
        playAllButton.addTarget(self, action: #selector(playAllTapped), for: .touchUpInside)

        addQueueButton.setTitle("加入队列", for: .normal)
        addQueueButton.setTitleColor(Theme.primary, for: .normal)
        addQueueButton.backgroundColor = Theme.primaryContainer
        addQueueButton.titleLabel?.font = Theme.labelLarge
        addQueueButton.layer.cornerRadius = 10
        addQueueButton.addTarget(self, action: #selector(addQueueTapped), for: .touchUpInside)

        saveButton.setTitle("收藏到本地", for: .normal)
        saveButton.setTitleColor(Theme.primary, for: .normal)
        saveButton.backgroundColor = Theme.primaryContainer
        saveButton.titleLabel?.font = Theme.labelLarge
        saveButton.layer.cornerRadius = 10
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        stack.addArrangedSubview(playAllButton)
        stack.addArrangedSubview(addQueueButton)
        stack.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            footerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerContainer.heightAnchor.constraint(equalToConstant: 84),

            stack.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -68),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            segmented.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            segmented.heightAnchor.constraint(equalToConstant: 32),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            tableView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),
        ])
    }

    // MARK: - Data loading

    private func loadTracks() {
        isLoading = true
        titleLabel.text = searchedPlaylist.name
        subtitleLabel.text = "\(sourceDisplayName(searchedPlaylist.source)) · \(searchedPlaylist.creator)"
        trackCountLabel.text = "正在拉取曲目…"
        if let urlStr = searchedPlaylist.coverUrl, let url = URL(string: urlStr) {
            NetworkManager.shared.loadImage(url: url.absoluteString) { [weak self] data in
                if let data = data { self?.artworkView.image = UIImage(data: data) }
            }
        }

        PlaylistImporter.shared.previewTracks(
            source: searchedPlaylist.source,
            listId: searchedPlaylist.sourceListId
        ) { [weak self] result in
            self?.isLoading = false
            switch result {
            case .failure(let e):
                self?.loadError = e.localizedDescription
                self?.trackCountLabel.text = "拉取失败：\(e.localizedDescription)"
            case .success(let res):
                let n = res.tracks.count
                self?.tracks = res.tracks
                self?.playlistName = res.name
                self?.trackPlayability = Array(repeating: false, count: n)
                if self?.titleLabel.text == nil || self?.titleLabel.text == self?.searchedPlaylist.name {
                    self?.titleLabel.text = res.name
                }
                self?.trackCountLabel.text = "\(n) 首 · \(self?.searchedPlaylist.creator ?? "")"
            }
            self?.tableView.reloadData()
        }
    }

    // MARK: - Actions

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        currentFilter = FilterMode(rawValue: sender.selectedSegmentIndex) ?? .all
        tableView.reloadData()
    }

    @objc private func playAllTapped() {
        guard !tracks.isEmpty else { return }
        runStreamingPlay(startFirst: true, fallBackHeader: "正在拉取可播放版本…")
    }
    @objc private func addQueueTapped() {
        guard !tracks.isEmpty else { return }
        runStreamingPlay(startFirst: false, fallBackHeader: "正在匹配歌曲…")
    }
    @objc private func saveTapped() {
        // 后台导入，立即关闭详情页。由全局 banner 接管进度。
        let job = PlaylistImporter.shared.importPlaylistAsync(
            source: searchedPlaylist.source,
            listId: searchedPlaylist.sourceListId,
            hintName: searchedPlaylist.name
        )
        showToast("「\(searchedPlaylist.name)」开始后台导入 (\(job.jobId.prefix(8)))")
        navigationController?.popViewController(animated: true)
    }

    /// 流式播放：按顺序匹配，第一首成功立刻开播；后续匹配到的追加到队列尾部
    private func runStreamingPlay(startFirst: Bool, fallBackHeader: String) {
        let title = self.title
        self.title = fallBackHeader
        var queueAdded = 0
        var firstPlayed = false
        var idx = 0
        let tracks = self.tracks

        func next() {
            if idx >= tracks.count {
                self.title = title
                if queueAdded == 0 {
                    self.showAlert("无可播放版本", message: "已尝试在所有已启用音源中匹配，但没有任何一首能取到播放链接。\n\n可换其他音源，或使用「收藏到本地」让匹配在后台慢慢找。")
                } else if !firstPlayed {
                    self.showToast("已加入 \(queueAdded) 首到队列尾部（未播放）")
                } else {
                    self.showToast("已加入剩余 \(queueAdded) 首到队列尾部")
                }
                return
            }
            let t = tracks[idx]; idx += 1
            SourceSwitcher.shared.findSong(name: t.name, singer: t.artist) { song in
                guard let song = song else {
                    DispatchQueue.main.async { next() }
                    return
                }
                DispatchQueue.main.async {
                    if startFirst && !firstPlayed {
                        PlayerManager.shared.play(song: song, queue: [song])
                        firstPlayed = true
                        self.showToast("正在播放：\(song.name) - \(song.singer)")
                        self.title = title
                    } else {
                        PlayerManager.shared.addToQueue(song)
                        queueAdded += 1
                    }
                    if startFirst && !firstPlayed {
                        // 单首即开播，不再追加
                        return
                    }
                    next()
                }
            }
        }
        next()
    }

    // MARK: - Helpers

    private func sourceDisplayName(_ key: String) -> String {
        ConfigStore.shared.displayName(for: key)
    }

    private func showToast(_ msg: String) {
        let toast = UILabel()
        toast.text = msg
        toast.font = Theme.bodyMedium
        toast.textColor = .white
        toast.numberOfLines = 0
        toast.textAlignment = .center
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        toast.layer.cornerRadius = 10
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
        toast.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        UIView.animate(withDuration: 0.2, delay: 1.4, options: [], animations: { toast.alpha = 0 },
                       completion: { _ in toast.removeFromSuperview() })
    }

    private func showAlert(_ title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    // MARK: - Filter helpers

    private func filteredTracks() -> [PlaylistImporter.Track] {
        switch currentFilter {
        case .all: return tracks
        case .playable:
            return tracks.enumerated().compactMap { trackPlayability.indices.contains($0.offset) && trackPlayability[$0.offset] ? $0.element : nil }
        case .unmatched:
            return tracks.enumerated().compactMap { trackPlayability.indices.contains($0.offset) && !trackPlayability[$0.offset] ? $0.element : nil }
        }
    }
}

// MARK: - UITableViewDataSource

extension SearchedPlaylistDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isLoading { return 0 }
        if loadError != nil { return 1 }
        return filteredTracks().count
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistTrackCell.reuseIdentifier, for: indexPath) as! PlaylistTrackCell
        let rows = filteredTracks()
        if let loadError = loadError, rows.isEmpty {
            cell.configureError(loadError)
            return cell
        }
        let track = rows[indexPath.row]
        cell.configure(track: track, index: indexPath.row + 1)
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = filteredTracks()
        guard indexPath.row < rows.count else { return }
        let track = rows[indexPath.row]
        SourceSwitcher.shared.findSong(name: track.name, singer: track.artist) { song in
            DispatchQueue.main.async {
                guard let song = song else {
                    self.showAlert("暂无可播放版本", message: "已尝试在所有已启用音源中匹配，但未找到「\(track.name)」的可播放版本。\n可切到「收藏到本地」让匹配在后台找，或换其他搜索关键字。")
                    return
                }
                PlayerManager.shared.play(song: song, queue: [song])
            }
        }
    }
}

// MARK: - PlaylistTrackCell

final class PlaylistTrackCell: UITableViewCell {
    static let reuseIdentifier = "PlaylistTrackCell"

    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let badgeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        indexLabel.font = Theme.bodySmall
        indexLabel.textColor = Theme.subtext
        indexLabel.textAlignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(indexLabel)

        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1
        contentView.addSubview(titleLabel)

        artistLabel.font = Theme.bodyMedium
        artistLabel.textColor = Theme.subtext
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.numberOfLines = 1
        contentView.addSubview(artistLabel)

        badgeLabel.font = Theme.bodySmall
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        badgeLabel.backgroundColor = Theme.primaryContainer
        contentView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            indexLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            indexLabel.widthAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),

            badgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            badgeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badgeLabel.heightAnchor.constraint(equalToConstant: 22),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(track: PlaylistImporter.Track, index: Int) {
        indexLabel.text = "\(index)"
        titleLabel.text = track.name
        artistLabel.text = track.artist
        badgeLabel.text = "查看"
    }
    func configureError(_ msg: String) {
        indexLabel.text = ""
        titleLabel.text = "加载失败"
        artistLabel.text = msg
        badgeLabel.text = ""
    }
}
