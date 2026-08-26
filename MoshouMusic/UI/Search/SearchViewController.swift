import UIKit

/// 搜索页 — Material Design 3 风格
/// 左侧垂直源切换 + 右侧搜索框 + 结果列表
class SearchViewController: UIViewController {

    private let searchField = MDSearchField()

    // 左侧源切换侧栏
    private let sidebar = UIView()
    private let sourceStack = UIStackView()

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

        // 搜索框 — 放在右侧内容区
        searchField.placeholder = "搜索歌曲、歌手、专辑"
        searchField.onTextChanged = { [weak self] text in
            self?.handleTextChanged(text)
        }
        searchField.onSearchTapped = { [weak self] text in
            self?.handleSearchTapped(text)
        }
        view.addSubview(searchField)

        // 左侧源切换侧栏
        view.addSubview(sidebar)
        sourceStack.axis = .vertical
        sourceStack.spacing = 10
        sourceStack.alignment = .fill
        sourceStack.distribution = .fill
        sidebar.addSubview(sourceStack)

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
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        [searchField, tableView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // 侧栏宽度（intrinsic 高度由 stack 决定 — 5×50pt + 4×10pt ≈ 290pt）
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            sidebar.widthAnchor.constraint(equalToConstant: 72),

            // 源 stack 填满侧栏
            sourceStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 4),
            sourceStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sourceStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sourceStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -4),

            // 搜索框：右侧
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            // 表格：右侧，紧贴搜索框下沿
            tableView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 4),
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
        sourceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for source in ids {
            let chip = createSourceChip(source: source)
            sourceStack.addArrangedSubview(chip)
        }
        // 确保选中态正确（首个选中源 + 给所有 chip 设置正确状态）
        for (i, source) in ids.enumerated() {
            if let chip = sourceStack.arrangedSubviews[i] as? UIButton {
                updateChipAppearance(chip, source: source, isSelected: source == selected)
            }
        }
    }

    private func createSourceChip(source: String) -> UIButton {
        let chip = UIButton(type: .custom)
        // 优先显示简称（"酷我"/"网易云"），在侧栏宽度下更紧凑
        let shortName = shortNameFor(source)
        chip.setTitle(shortName, for: .normal)
        chip.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        chip.titleLabel?.adjustsFontSizeToFitWidth = true
        chip.titleLabel?.minimumScaleFactor = 0.7
        chip.titleLabel?.lineBreakMode = .byClipping
        chip.layer.cornerRadius = 14
        // 抑制系统 tint 渗透
        chip.tintColor = .clear
        chip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        if let index = ConfigStore.shared.selectableSourceIds.firstIndex(of: source) {
            chip.tag = index
        }
        chip.addTarget(self, action: #selector(sourceChipTapped(_:)), for: .touchUpInside)

        let selected = ConfigStore.shared.currentSource == source
        updateChipAppearance(chip, source: source, isSelected: selected)
        // 强制刷新布局
        chip.setNeedsLayout()

        // 固定短矩形高度 (50pt)，让整列堆叠尺寸可控
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return chip
    }

    /// 短名用于 72pt 宽侧栏
    private func shortNameFor(_ source: String) -> String {
        switch source {
        case "kw": return "酷我"
        case "tx": return "QQ"
        case "wy": return "云"
        case "kg": return "酷狗"
        case "mg": return "咪咕"
        default: return ConfigStore.shared.displayName(for: source)
        }
    }

    private func updateChipAppearance(_ chip: UIButton, source: String, isSelected: Bool) {
        if isSelected {
            // 选中：深色饱和背景 + 白色字（强制所有状态都白，避免被高亮/tint覆盖）
            let bg = Theme.sourceColorDark(source)
            chip.backgroundColor = bg
            chip.setTitleColor(.white, for: .normal)
            chip.setTitleColor(.white, for: .highlighted)
            chip.setTitleColor(.white, for: .selected)
            chip.setTitleColor(.white.withAlphaComponent(0.7), for: .disabled)
        } else {
            // 未选中：浅色容器 + 鲜艳字
            chip.backgroundColor = Theme.sourceColorLight(source)
            let fg = Theme.sourceColor(source)
            chip.setTitleColor(fg, for: .normal)
            chip.setTitleColor(fg, for: .highlighted)
            chip.setTitleColor(fg, for: .selected)
            chip.setTitleColor(fg.withAlphaComponent(0.5), for: .disabled)
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
            if let chip = sourceStack.arrangedSubviews[i] as? UIButton {
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
