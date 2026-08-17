import UIKit

/// 搜索页 — Material Design 3 风格
/// 药丸搜索栏 + 彩色 Chips 音源切换 + 搜索结果列表
class SearchViewController: UIViewController {

    private let searchBar = UISearchBar()
    private let sourceChipsScrollView = UIScrollView()
    private let sourceChipsContainer = UIStackView()
    private let tableView = UITableView()
    private let emptyLabel = UILabel()

    private var searchResults: [Song] = []
    private var currentSource: String = "kw"
    private var currentKeyword: String = ""
    private var searchTask: DispatchWorkItem?

    private let sources = ["kw", "tx", "mg", "wy", "kg"]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "搜索"
        navigation.largeTitleDisplayMode = .always

        // 搜索栏
        searchBar.placeholder = "搜索歌曲、歌手、专辑"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.searchTextField.backgroundColor = Theme.surfaceVariant
        searchBar.searchTextField.layer.cornerRadius = Theme.cornerFull
        searchBar.searchTextField.clipsToBounds = true
        searchBar.tintColor = Theme.primary
        navigationItem.titleView = searchBar

        // 音源 Chips
        sourceChipsScrollView.showsHorizontalScrollIndicator = false
        sourceChipsScrollView.backgroundColor = .clear
        view.addSubview(sourceChipsScrollView)

        sourceChipsContainer.axis = .horizontal
        sourceChipsContainer.spacing = 8
        sourceChipsContainer.alignment = .center
        sourceChipsScrollView.addSubview(sourceChipsContainer)

        setupSourceChips()

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
        [sourceChipsScrollView, tableView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        sourceChipsContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Chips
            sourceChipsScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            sourceChipsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceChipsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sourceChipsScrollView.heightAnchor.constraint(equalToConstant: 44),

            sourceChipsContainer.topAnchor.constraint(equalTo: sourceChipsScrollView.topAnchor),
            sourceChipsContainer.leadingAnchor.constraint(equalTo: sourceChipsScrollView.leadingAnchor, constant: 12),
            sourceChipsContainer.trailingAnchor.constraint(equalTo: sourceChipsScrollView.trailingAnchor, constant: -12),
            sourceChipsContainer.bottomAnchor.constraint(equalTo: sourceChipsScrollView.bottomAnchor),
            sourceChipsContainer.heightAnchor.constraint(equalTo: sourceChipsScrollView.heightAnchor),

            // 表格
            tableView.topAnchor.constraint(equalTo: sourceChipsScrollView.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 空状态
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 音源 Chips

    private func setupSourceChips() {
        for source in sources {
            let chip = createSourceChip(source: source)
            sourceChipsContainer.addArrangedSubview(chip)
        }
    }

    private func createSourceChip(source: String) -> UIButton {
        let chip = UIButton(type: .system)
        chip.setTitle(Theme.sourceName(source), for: .normal)
        chip.titleLabel?.font = Theme.labelLarge
        chip.layer.cornerRadius = Theme.cornerFull
        chip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        chip.tag = sources.firstIndex(of: source) ?? 0
        chip.addTarget(self, action: #selector(sourceChipTapped(_:)), for: .touchUpInside)

        updateChipAppearance(chip, source: source, isSelected: source == currentSource)

        return chip
    }

    private func updateChipAppearance(_ chip: UIButton, source: String, isSelected: Bool) {
        if isSelected {
            chip.backgroundColor = Theme.sourceColor(source)
            chip.setTitleColor(.white, for: .normal)
        } else {
            chip.backgroundColor = Theme.sourceColorLight(source)
            chip.setTitleColor(Theme.sourceColor(source), for: .normal)
        }
    }

    @objc private func sourceChipTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index < sources.count else { return }

        currentSource = sources[index]

        // 更新所有 Chip 外观
        for (i, source) in sources.enumerated() {
            if let chip = sourceChipsContainer.arrangedSubviews[i] as? UIButton {
                updateChipAppearance(chip, source: source, isSelected: i == index)
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

        // 显示加载状态
        emptyLabel.text = "搜索中..."

        ScriptEngine.shared.search(
            keyword: currentKeyword,
            page: 1,
            source: currentSource
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let list):
                    self.searchResults = list.compactMap { Song(from: $0, source: self.currentSource) }
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

// MARK: - UISearchBarDelegate

extension SearchViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 防抖
        searchTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.currentKeyword = searchText.trimmingCharacters(in: .whitespaces)
            if self?.currentKeyword.isEmpty == false {
                ConfigStore.shared.addSearchHistory(self!.currentKeyword)
                self?.performSearch()
            } else {
                self?.searchResults = []
                self?.tableView.reloadData()
                self?.emptyLabel.text = "搜索你喜欢的音乐"
                self?.emptyLabel.isHidden = false
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        currentKeyword = searchBar.text ?? ""
        if !currentKeyword.isEmpty {
            ConfigStore.shared.addSearchHistory(currentKeyword)
            performSearch()
        }
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

        // 添加到歌单
        alert.addAction(UIAlertAction(title: "添加到歌单", style: .default) { _ in
            self.showPlaylistPicker(for: song)
        })

        // 下一首播放
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
