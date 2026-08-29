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
    private let playAllButton = UIButton(type: .system)
    private let addQueueButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    private enum FilterMode: Int { case all = 0, playable = 1, unmatched = 2 }
    private var currentFilter: FilterMode = .all

    /// 每首曲目的可播预检结果（三态）：
    /// - `nil`  = 还没检测
    /// - `true` = 已在本机启用音源里找到可播版本
    /// - `false`= 检测过但没找到
    /// 用三态是为了让「无匹配」只放**真正检测过且没找到**的，还在检测中的不算无匹配
    /// （v1.0.41 之前是全 false 且从不更新，导致「可播」恒空、「无匹配」包含全部）。
    private var trackPlayability: [Bool?] = []
    /// 预检是否还在进行
    private var isProbing = false

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
        setupSegmented()
        // ⚠️ 顺序不能变：setupTable 负责 view.addSubview(tableView)，
        // 而 setupToolbar 里会激活 tableView 的约束（引用 stack.bottom / view）。
        // 若 setupTable 排在 setupToolbar 之后，tableView 还没进视图层级就被约束，
        // 会抛 NSGenericException "no common ancestor"（v1.0.45 真机崩溃）。
        setupTable()
        setupToolbar()
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
        // 限制 2 行 + 字号自动缩放：长标题缩到 60% 也能放下，固定 3 行会撑大 header 把 tableView 挤掉
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel.font = Theme.bodyMedium
        subtitleLabel.textColor = Theme.subtext
        subtitleLabel.numberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        trackCountLabel.font = Theme.bodySmall
        trackCountLabel.textColor = Theme.subtext
        trackCountLabel.numberOfLines = 1
        trackCountLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(trackCountLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // 固定 130pt：title 2 行 (~44) + subtitle 1 行 (~18) + trackCount 1 行 (~16) + spacing 12 + padding 12 = ~102
            // 留 28pt 余量避免长字符撑大
            headerView.heightAnchor.constraint(equalToConstant: 130),

            artworkView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            artworkView.topAnchor.constraint(equalTo: headerView.topAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 100),
            artworkView.heightAnchor.constraint(equalToConstant: 100),

            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            trackCountLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            trackCountLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            trackCountLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
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
        // 按内容分配宽度（iOS 14+）：「可播(122) 检测中 22」宽、「无匹配(0)」窄
        // user 期望可播加宽、无匹配缩短
        if #available(iOS 14.0, *) {
            segmented.apportionsSegmentWidthsByContent = true
        }
        segmented.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        view.addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            segmented.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            segmented.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // 顶部工具栏：3 个按钮（全部播放 / 加入队列 / 收藏到本地），
    // 把原来底部 footer 的功能提到 segmented 下方，tableView 占据剩余到底部
    private func setupToolbar() {
        // 防御：下面要给 tableView 激活约束，若它还没进视图层级会抛
        // NSGenericException "no common ancestor"。这里幂等补一次 addSubview。
        if tableView.superview == nil { view.addSubview(tableView) }

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        view.addSubview(stack)

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
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])

        // tableView 在 toolbar 下方、到 safeArea.bottom（tab bar 之上的安全区底部）
        // —— 占据下半部分所有空间，让歌名列表完整显示
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
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
            // 兜底：结果处理全是 UI（label / reloadData），强制回主线程
            DispatchQueue.main.async { self?.handlePreviewResult(result) }
        }
    }

    private func handlePreviewResult(
        _ result: Swift.Result<(name: String, tracks: [PlaylistImporter.Track], total: Int), Error>
    ) {
        isLoading = false
        switch result {
        case .failure(let e):
            loadError = e.localizedDescription
            trackCountLabel.text = "拉取失败：\(e.localizedDescription)"
        case .success(let res):
            let n = res.tracks.count
            tracks = res.tracks
            playlistName = res.name
            // 初始为「未检测」，由后台预检逐首填 true/false
            trackPlayability = Array(repeating: nil, count: n)
            if titleLabel.text == nil || titleLabel.text == searchedPlaylist.name {
                titleLabel.text = res.name
            }
            trackCountLabel.text = "\(n) 首 · \(searchedPlaylist.creator)"
        }
        tableView.reloadData()
        refreshSegmentTitles()
        startPlayabilityProbe()
    }

    // MARK: - 可播预检

    /// 后台串行逐首探测：哪些曲目能在本机已启用音源里找到可播版本。
    /// 一次只探测一首，避免把音源打爆；结果节流回主线程刷新列表。
    private func startPlayabilityProbe() {
        guard !tracks.isEmpty else { return }
        isProbing = true
        let total = tracks.count
        var idx = 0
        var lastFlush = Date()

        func step() {
            // 页面已离屏就停止，避免无谓请求
            guard self.view.window != nil else {
                DispatchQueue.main.async { [weak self] in self?.isProbing = false }
                return
            }
            guard idx < total else {
                DispatchQueue.main.async { [weak self] in
                    self?.isProbing = false
                    self?.refreshSegmentTitles()
                    self?.tableView.reloadData()
                }
                return
            }
            let i = idx
            let t = tracks[i]
            idx += 1
            SourceSwitcher.shared.findSong(name: t.name, singer: t.artist) { [weak self] song in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard i < self.trackPlayability.count else { step(); return }
                    self.trackPlayability[i] = (song != nil)
                    // 节流刷新：0.6 秒最多一次，避免逐首 reload 造成卡顿
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) > 0.6 || idx >= total {
                        lastFlush = now
                        self.refreshSegmentTitles()
                        self.tableView.reloadData()
                    }
                    step()
                }
            }
        }
        step()
    }

    /// 刷新分段标题与副标题，让「可播/无匹配」数量和检测进度可见
    private func refreshSegmentTitles() {
        let playable = trackPlayability.filter { $0 == true }.count
        let unmatched = trackPlayability.filter { $0 == false }.count
        let pending = trackPlayability.filter { $0 == nil }.count
        segmented.setTitle("全部(\(tracks.count))", forSegmentAt: 0)
        segmented.setTitle(pending > 0 ? "可播(\(playable)) 检测中\(pending)" : "可播(\(playable))",
                           forSegmentAt: 1)
        segmented.setTitle("无匹配(\(unmatched))", forSegmentAt: 2)

        if !tracks.isEmpty {
            if isProbing && pending > 0 {
                trackCountLabel.text = "\(tracks.count) 首 · 已检测 \(playable + unmatched)/\(tracks.count)"
            } else {
                trackCountLabel.text = "\(tracks.count) 首 · 可播 \(playable) · 无匹配 \(unmatched)"
            }
        }
    }

    // MARK: - Actions

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        currentFilter = FilterMode(rawValue: sender.selectedSegmentIndex) ?? .all
        tableView.reloadData()
    }

    @objc private func playAllTapped() {
        guard !tracks.isEmpty else { return }
        // 先清空当前播放队列（user 期望：点全部播放就只听这个歌单，不跟旧队列混）
        PlayerManager.shared.clearQueue()
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
                // 匹配到的可能是 Live/翻唱/重制版，名字与列表里的原曲不一致。
                // 这里沿用列表的歌名歌手来显示，播放链接仍用匹配到的版本。
                let playSong = song.withDisplay(name: t.name, singer: t.artist)
                DispatchQueue.main.async {
                    if startFirst && !firstPlayed {
                        PlayerManager.shared.play(song: playSong, queue: [playSong])
                        firstPlayed = true
                        self.showToast("正在播放：\(playSong.name) - \(playSong.singer)")
                        self.title = title
                    } else {
                        PlayerManager.shared.addToQueue(playSong)
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
            return tracks.enumerated().compactMap {
                trackPlayability.indices.contains($0.offset) && trackPlayability[$0.offset] == true
                    ? $0.element : nil
            }
        case .unmatched:
            // 只放「检测过且确实没找到」的；还在检测中的（nil）留在「全部」里
            return tracks.enumerated().compactMap {
                trackPlayability.indices.contains($0.offset) && trackPlayability[$0.offset] == false
                    ? $0.element : nil
            }
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
                // 沿用列表里的歌名歌手显示，避免匹配到 Live/翻唱版时显示与原曲不符
                let playSong = song.withDisplay(name: track.name, singer: track.artist)
                PlayerManager.shared.play(song: playSong, queue: [playSong])
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
