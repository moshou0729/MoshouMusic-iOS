import UIKit

/// 搜索页 — Material Design 3 风格
/// 药丸搜索栏 + 彩色 Chips 音源切换 (可持久化, 支持本机自定义音源) + 搜索结果列表
class SearchViewController: UIViewController {

    private let searchField = MDSearchField()
    private let sourceChipsScrollView = UIScrollView()
    private let sourceChipsContainer = UIStackView()
    private let tableView = UITableView()
    private let emptyLabel = UILabel()

    private var searchResults: [Song] = []
    private var currentKeyword: String = ""
    private var searchTask: DispatchWorkItem?

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

        // 搜索框 — 放在内容视图内的普通子视图，不进导航栏 titleView
        searchField.placeholder = "搜索歌曲、歌手、专辑"
        searchField.onTextChanged = { [weak self] text in
            self?.handleTextChanged(text)
        }
        searchField.onSearchTapped = { [weak self] text in
            self?.handleSearchTapped(text)
        }
        view.addSubview(searchField)

        // 音源 Chips
        sourceChipsScrollView.showsHorizontalScrollIndicator = false
        sourceChipsScrollView.backgroundColor = .clear
        view.addSubview(sourceChipsScrollView)

        sourceChipsContainer.axis = .horizontal
        sourceChipsContainer.spacing = 8
        sourceChipsContainer.alignment = .center
        sourceChipsScrollView.addSubview(sourceChipsContainer)

        reloadChips()

        // 表格
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongCell.self, forCellReuseIdentifier: SongCell.reuseIdentifier)
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
        [searchField, sourceChipsScrollView, tableView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        sourceChipsContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sourceChipsScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            sourceChipsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceChipsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sourceChipsScrollView.heightAnchor.constraint(equalToConstant: 44),

            sourceChipsContainer.topAnchor.constraint(equalTo: sourceChipsScrollView.topAnchor),
            sourceChipsContainer.leadingAnchor.constraint(equalTo: sourceChipsScrollView.leadingAnchor, constant: 12),
            sourceChipsContainer.trailingAnchor.constraint(equalTo: sourceChipsScrollView.trailingAnchor, constant: -12),
            sourceChipsContainer.bottomAnchor.constraint(equalTo: sourceChipsScrollView.bottomAnchor),
            sourceChipsContainer.heightAnchor.constraint(equalTo: sourceChipsScrollView.heightAnchor),

            tableView.topAnchor.constraint(equalTo: sourceChipsScrollView.bottomAnchor, constant: 4),
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
        let selected = ConfigStore.shared.currentSource
        sourceChipsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for source in ids {
            let chip = createSourceChip(source: source)
            sourceChipsContainer.addArrangedSubview(chip)
        }
        // 确保选中态正确
        for (i, source) in ids.enumerated() {
            if let chip = sourceChipsContainer.arrangedSubviews[i] as? UIButton {
                updateChipAppearance(chip, source: source, isSelected: source == selected)
            }
        }
    }

    private func createSourceChip(source: String) -> UIButton {
        let chip = UIButton(type: .custom)
        chip.setTitle(ConfigStore.shared.displayName(for: source), for: .normal)
        chip.titleLabel?.font = Theme.labelLarge
        chip.layer.cornerRadius = Theme.cornerFull
        chip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        if let index = ConfigStore.shared.selectableSourceIds.firstIndex(of: source) {
            chip.tag = index
        }
        chip.addTarget(self, action: #selector(sourceChipTapped(_:)), for: .touchUpInside)

        let selected = ConfigStore.shared.currentSource == source
        updateChipAppearance(chip, source: source, isSelected: selected)

        return chip
    }

    private func updateChipAppearance(_ chip: UIButton, source: String, isSelected: Bool) {
        if isSelected {
            // 选中：用音源标志色做背景，文字按背景亮度自动取黑/白，保证对比可读
            let bg = Theme.sourceColor(source)
            chip.backgroundColor = bg
            chip.setTitleColor(Theme.contrastingTextColor(for: bg), for: .normal)
        } else {
            chip.backgroundColor = Theme.sourceColorLight(source)
            chip.setTitleColor(Theme.sourceColor(source), for: .normal)
        }
    }

    @objc private func sourceChipTapped(_ sender: UIButton) {
        let index = sender.tag
        let ids = ConfigStore.shared.selectableSourceIds
        guard index < ids.count else { return }

        let source = ids[index]
        ConfigStore.shared.currentSource = source

        for (i, s) in ids.enumerated() {
            if let chip = sourceChipsContainer.arrangedSubviews[i] as? UIButton {
                updateChipAppearance(chip, source: s, isSelected: i == index)
            }
        }

        // 重新搜索
        if !currentKeyword.isEmpty {
            performSearch()
        }
    }

    // MARK: - 搜索

    private func performSearch() {
        guard !currentKeyword.isEmpty else { return }

        emptyLabel.text = "搜索中..."

        let source = ConfigStore.shared.currentSource
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
                    // 原唱优先、其次按音质排序（启发式，依赖来源是否标注原唱/音质）
                    self.searchResults.sort {
                        if $0.isOriginalGuess != $1.isOriginalGuess {
                            return $0.isOriginalGuess
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
        return searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SongCell.reuseIdentifier, for: indexPath) as! SongCell
        let song = searchResults[indexPath.row]
        cell.configure(with: song, index: indexPath.row)

        cell.onMoreTapped = { [weak self] song in
            self?.showMoreOptions(for: song)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let song = searchResults[indexPath.row]
        PlayerManager.shared.play(song: song, queue: searchResults)
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
