import UIKit

/// 搜索页 — Material Design 3 风格
/// 顶部横向 5 chip：未选中=透明+该源色字；选中=圆角矩形+该源色背景（取未选中时的颜色值）+白字
class SearchViewController: UIViewController {

    private let searchField = MDSearchField()

    /// 顶部横向源切换
    private let chipRow = UIStackView()

    /// 搜索模式：歌曲（点击只播这一首）/ 歌单（点击把队列替换为结果列表）
    private enum SearchMode: Int { case song = 0, playlist = 1 }
    private var searchMode: SearchMode = .song
    private let modeSegment: UISegmentedControl = {
        let sg = UISegmentedControl(items: ["歌曲", "歌单"])
        sg.selectedSegmentIndex = SearchMode.song.rawValue
        return sg
    }()

    private let tableView = UITableView()
    private let emptyLabel = UILabel()

    private var searchResults: [Song] = []
    private var playlistResults: [SearchedPlaylist] = []
    private var currentKeyword: String = ""
    private var searchTask: DispatchWorkItem?
    private var hud: UIAlertController?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 返回时重建 Chips（可能新增了自定义音源 / 切换了默认源）
        reloadChips()
        // 主题可能在设置页被切换，重新上色
        view.backgroundColor = Theme.bg
        searchField.applyTheme()
        emptyLabel.textColor = Theme.subtext
        tableView.reloadData()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "搜索"
        navigationItem.largeTitleDisplayMode = .always

        // 搜索框 — 顶部
        searchField.placeholder = "搜索歌曲、歌手、专辑"
        searchField.onTextChanged = { [weak self] text in
            self?.handleTextChanged(text)
        }
        searchField.onSearchTapped = { [weak self] text in
            self?.handleSearchTapped(text)
        }
        view.addSubview(searchField)

        // 搜索模式分段控件（歌曲 / 歌单）
        modeSegment.selectedSegmentTintColor = Theme.primary
        modeSegment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        modeSegment.setTitleTextAttributes([.foregroundColor: Theme.primary], for: .normal)
        modeSegment.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        view.addSubview(modeSegment)

        // 顶部横向 5 chip 行
        chipRow.axis = .horizontal
        chipRow.spacing = 10
        chipRow.alignment = .center
        chipRow.distribution = .equalSpacing
        view.addSubview(chipRow)

        reloadChips()

        // 表格
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongCell.self, forCellReuseIdentifier: SongCell.reuseIdentifier)
        tableView.register(PlaylistSearchCell.self, forCellReuseIdentifier: PlaylistSearchCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 68
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)

        // 空状态
        emptyLabel.text = "搜索你喜欢的音乐"
        emptyLabel.font = Theme.bodyLarge
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        view.addSubview(emptyLabel)

        setupConstraints()
    }

    private func setupConstraints() {
        [searchField, modeSegment, chipRow, tableView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 搜索框：顶部
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // 搜索模式分段：紧贴搜索框下沿
            modeSegment.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            modeSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modeSegment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // 横向 chip 行：紧贴分段下沿，左右各 16pt 边距 — 撑满整行避免右侧大空白
            chipRow.topAnchor.constraint(equalTo: modeSegment.bottomAnchor, constant: 12),
            chipRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            chipRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            chipRow.heightAnchor.constraint(equalToConstant: 38),

            // 表格：紧贴 chip 行下沿
            tableView.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 音源 Chips

    private func reloadChips() {
        let ids = ConfigStore.shared.selectableSourceIds
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, source) in ids.enumerated() {
            let chip = createSourceChip(source: source, tag: i)
            chipRow.addArrangedSubview(chip)
        }
    }

    private func createSourceChip(source: String, tag: Int) -> UIButton {
        let chip = UIButton(type: .custom)
        let name = ConfigStore.shared.displayName(for: source)
        chip.setTitle(name, for: .normal)
        chip.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        chip.tag = tag
        chip.layer.cornerRadius = 12
        chip.layer.masksToBounds = true
        // 抑制系统 tint 渗透
        chip.tintColor = .clear
        chip.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        chip.addTarget(self, action: #selector(sourceChipTapped(_:)), for: .touchUpInside)

        let isSelected = ConfigStore.shared.currentSource == source
        updateChipAppearance(chip, source: source, isSelected: isSelected)
        return chip
    }

    private func updateChipAppearance(_ chip: UIButton, source: String, isSelected: Bool) {
        let base = Theme.sourceColor(source)        // 该源未选中时显示的颜色值
        if isSelected {
            // 选中：背景 = 该源未选中时的颜色值 + 白字 + 圆角矩形
            chip.backgroundColor = base
            chip.setTitleColor(.white, for: .normal)
            chip.setTitleColor(.white, for: .highlighted)
            chip.setTitleColor(.white, for: .selected)
            chip.setTitleColor(.white.withAlphaComponent(0.7), for: .disabled)
        } else {
            // 未选中：透明背景 + 该源色字
            chip.backgroundColor = .clear
            chip.setTitleColor(base, for: .normal)
            chip.setTitleColor(base, for: .highlighted)
            chip.setTitleColor(base, for: .selected)
            chip.setTitleColor(base.withAlphaComponent(0.5), for: .disabled)
        }
        // 抑制 state-driven 颜色回弹
        chip.tintColor = .clear
    }

    @objc private func sourceChipTapped(_ sender: UIButton) {
        let index = sender.tag
        let ids = ConfigStore.shared.selectableSourceIds
        guard index < ids.count else { return }

        let source = ids[index]
        ConfigStore.shared.currentSource = source

        for (i, s) in ids.enumerated() {
            if let chip = chipRow.arrangedSubviews[i] as? UIButton {
                updateChipAppearance(chip, source: s, isSelected: i == index)
            }
        }

        // 重新搜索
        if !currentKeyword.isEmpty {
            performSearch()
        }
    }

    @objc private func modeChanged(_ sender: UISegmentedControl) {
        searchMode = SearchMode(rawValue: sender.selectedSegmentIndex) ?? .song
        // 歌曲 / 歌单 是两种不同搜索，切换后若已有关键词则立即重搜
        if !currentKeyword.isEmpty {
            performSearch()
        } else {
            emptyLabel.text = searchMode == .playlist ? "搜索你喜欢的歌单" : "搜索你喜欢的音乐"
        }
    }

    // MARK: - 搜索

    private func performSearch() {
        guard !currentKeyword.isEmpty else { return }

        emptyLabel.text = "搜索中..."

        let source = ConfigStore.shared.currentSource
        if searchMode == .playlist {
            // 歌单模式：原生逐音源搜索「歌单名字 + id」
            PlaylistSearchService.shared.search(keyword: currentKeyword, source: source) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let list):
                        self.playlistResults = list
                        self.tableView.reloadData()
                        if list.isEmpty {
                            let supported = PlaylistSearchService.supportedSources.contains(source)
                            self.emptyLabel.text = supported
                                ? "没有找到相关歌单"
                                : "该音源暂不支持歌单搜索（请切换到 网易云 / QQ / 酷狗）"
                        } else {
                            self.emptyLabel.text = ""
                        }
                        self.emptyLabel.isHidden = !list.isEmpty
                    case .failure(let error):
                        Logger.error("歌单搜索失败: \(error.localizedDescription)")
                        self.playlistResults = []
                        self.tableView.reloadData()
                        self.emptyLabel.text = "歌单搜索失败：\(error.localizedDescription)"
                        self.emptyLabel.isHidden = false
                    }
                }
            }
        } else {
            // 歌曲模式：走音源脚本 musicSearch
            ScriptEngine.shared.search(
                keyword: currentKeyword,
                page: 1,
                source: source
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    switch result {
                    case .success(let list):
                        self.searchResults = list.compactMap { Song(from: $0, source: source) }
                        // 原唱综合评分高的优先（同时排除翻唱/live/伴奏版）；同等评分再看音质
                        self.searchResults.sort {
                            if $0.originalScore != $1.originalScore {
                                return $0.originalScore > $1.originalScore
                            }
                            if $0.qualityRank != $1.qualityRank {
                                return $0.qualityRank > $1.qualityRank
                            }
                            return false
                        }
                        self.tableView.reloadData()
                        self.emptyLabel.text = self.searchResults.isEmpty ? "没有找到相关音乐" : ""
                        self.emptyLabel.isHidden = !self.searchResults.isEmpty

                    case .failure(let error):
                        Logger.error("搜索失败: \(error.localizedDescription)")
                        self.searchResults = []
                        self.tableView.reloadData()
                        self.emptyLabel.text = "搜索失败，请检查音源脚本"
                        self.emptyLabel.isHidden = false
                    }
                }
            }
        }
    }
}

// MARK: - 搜索框回调

extension SearchViewController {

    /// 输入变化 — 0.5s 防抖后自动搜索
    fileprivate func handleTextChanged(_ text: String) {
        searchTask?.cancel()
        let keyword = text.trimmingCharacters(in: .whitespaces)

        if keyword.isEmpty {
            currentKeyword = ""
            searchResults = []
            tableView.reloadData()
            emptyLabel.text = "搜索你喜欢的音乐"
            emptyLabel.isHidden = false
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.currentKeyword = keyword
            ConfigStore.shared.addSearchHistory(keyword)
            self.performSearch()
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    /// 点击键盘搜索键 — 立即搜索
    fileprivate func handleSearchTapped(_ text: String) {
        searchTask?.cancel()
        currentKeyword = text.trimmingCharacters(in: .whitespaces)
        guard !currentKeyword.isEmpty else { return }
        ConfigStore.shared.addSearchHistory(currentKeyword)
        performSearch()
    }
}

// MARK: - UITableViewDataSource & Delegate

extension SearchViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return searchMode == .playlist ? playlistResults.count : searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if searchMode == .playlist {
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistSearchCell.reuseIdentifier, for: indexPath) as! PlaylistSearchCell
            cell.configure(with: playlistResults[indexPath.row], index: indexPath.row)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: SongCell.reuseIdentifier, for: indexPath) as! SongCell
        let song = searchResults[indexPath.row]
        cell.configure(with: song, index: indexPath.row)

        cell.onMoreTapped = { [weak self] song in
            self?.showMoreOptions(for: song)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if searchMode == .playlist {
            // 歌单模式：点击某一歌单 → 拉取整张并播放
            importPlaylist(playlistResults[indexPath.row])
        } else {
            // 歌曲模式：只播放这一首
            let song = searchResults[indexPath.row]
            PlayerManager.shared.play(song: song, queue: [song])
        }
    }
}

// MARK: - 更多操作

extension SearchViewController {
    private func showMoreOptions(for song: Song) {
        let alert = UIAlertController(title: song.name, message: song.singer, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "添加到歌单", style: .default) { _ in
            self.showPlaylistPicker(for: song)
        })

        alert.addAction(UIAlertAction(title: "下一首播放", style: .default) { _ in
            PlayerManager.shared.addToQueue(song)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showPlaylistPicker(for song: Song) {
        let alert = UIAlertController(title: "选择歌单", message: nil, preferredStyle: .actionSheet)

        for playlist in PlaylistStore.shared.playlists {
            alert.addAction(UIAlertAction(title: playlist.name, style: .default) { _ in
                PlaylistStore.shared.addSong(song, to: playlist.id)
            })
        }

        alert.addAction(UIAlertAction(title: "新建歌单", style: .default) { _ in
            self.showCreatePlaylistDialog { name in
                let playlist = PlaylistStore.shared.create(name: name)
                PlaylistStore.shared.addSong(song, to: playlist.id)
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showCreatePlaylistDialog(completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "新建歌单", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "歌单名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            if let name = alert.textFields?.first?.text, !name.isEmpty {
                completion(name)
            }
        })
        present(alert, animated: true)
    }
}

// MARK: - 歌单导入（歌单搜索点击）

extension SearchViewController {
    /// 点击搜索结果里的某个歌单：拉取整张 → 匹配本机音源 → 加入队列并播放
    private func importPlaylist(_ pl: SearchedPlaylist) {
        let hud = showHUD("正在拉取歌单「\(pl.name)」…")
        PlaylistImporter.shared.importPlaylist(source: pl.source, listId: pl.sourceListId, hintName: pl.name, progress: { _ in }) { result in
            DispatchQueue.main.async {
                hud.dismiss(animated: true)
                self.hud = nil
                switch result {
                case .failure(let e):
                    self.showAlert("导入失败", message: e.localizedDescription)
                case .success(let res):
                    let songs = res.playlist.songs
                    if let first = songs.first {
                        PlayerManager.shared.play(song: first, queue: songs)
                    }
                    self.showToast("已导入「\(res.playlistName)」：\(res.matched)/\(res.total) 首匹配，已加入播放队列")
                }
            }
        }
    }

    private func showHUD(_ msg: String) -> UIAlertController {
        let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        present(a, animated: true)
        hud = a
        return a
    }

    private func showAlert(_ title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default))
        present(a, animated: true)
    }

    private func showToast(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            alert.dismiss(animated: true)
        }
    }
}
