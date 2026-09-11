import UIKit

/// v1.0.153：播放页「添加到歌单」面板（Material 3 底部抽屉）
///
/// 与搜索页那套 actionSheet 不同：这里必须让用户看见「当前这首歌是否已经在某个歌单里」，
/// 所以用可勾选的列表；再次点按已勾选条目 = 从该歌单移出（误加了能撤回，不用跳去歌单页）。
/// 「最近播放」是系统自动维护的，不作为添加目标，列表里剔除。
final class AddToPlaylistViewController: UIViewController {

    private let song: Song

    private let grabber = UIView()
    private let titleLabel = UILabel()
    private let songLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let headerRow = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let createButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    private var playlists: [Playlist] = []
    private var addedIds: Set<String> = []

    init(song: Song) {
        self.song = song
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        setupUI()
        reload()

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: PlaylistStore.didChangeNotification, object: nil)
    }

    // MARK: - UI

    private func setupUI() {
        grabber.backgroundColor = Theme.border
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "添加到歌单"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = Theme.text

        songLabel.text = "\(song.name) · \(song.singer)"
        songLabel.font = Theme.bodySmall
        songLabel.textColor = Theme.subtext
        songLabel.numberOfLines = 1
        songLabel.lineBreakMode = .byTruncatingTail

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = Theme.border
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = UIStackView(arrangedSubviews: [titleLabel, songLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .leading

        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 12
        headerRow.addArrangedSubview(titleStack)
        headerRow.addArrangedSubview(closeButton)
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AddToPlaylistCell.self, forCellReuseIdentifier: AddToPlaylistCell.reuseId)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 62
        tableView.showsVerticalScrollIndicator = false
        tableView.translatesAutoresizingMaskIntoConstraints = false

        // 底部主按钮：新建歌单（M3 filled button）
        createButton.setTitle("新建歌单", for: .normal)
        createButton.titleLabel?.font = Theme.labelLarge
        createButton.setTitleColor(Theme.onPrimary, for: .normal)
        createButton.backgroundColor = Theme.primary
        createButton.layer.cornerRadius = 24
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
        createButton.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "还没有歌单，点下面「新建歌单」建一个吧"
        emptyLabel.font = Theme.bodyMedium
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grabber)
        view.addSubview(headerRow)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(createButton)

        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            headerRow.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            tableView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: createButton.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            createButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            createButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            createButton.heightAnchor.constraint(equalToConstant: 48),
            createButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - 数据

    private func reload() {
        playlists = PlaylistStore.shared.playlists.filter { $0.name != PlaylistStore.recentPlayedName }
        var ids = Set<String>()
        for p in playlists where p.songs.contains(where: { $0.id == song.id }) {
            ids.insert(p.id)
        }
        addedIds = ids
        emptyLabel.isHidden = !playlists.isEmpty
        tableView.reloadData()
    }

    @objc private func storeChanged() {
        reload()
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func createTapped() {
        let alert = UIAlertController(title: "新建歌单", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "歌单名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建并加入", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let name = alert.textFields?.first?.text ?? ""
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let playlist = PlaylistStore.shared.create(name: trimmed)
            PlaylistStore.shared.addSong(self.song, to: playlist.id)
            self.reload()
            self.toast("已添加到「\(trimmed)」")
        })
        present(alert, animated: true)
    }

    private func toggle(at index: Int) {
        guard index >= 0, index < playlists.count else { return }
        let playlist = playlists[index]
        if addedIds.contains(playlist.id) {
            PlaylistStore.shared.removeSong(songId: song.id, from: playlist.id)
            toast("已从「\(playlist.name)」移出")
        } else {
            PlaylistStore.shared.addSong(song, to: playlist.id)
            toast("已添加到「\(playlist.name)」")
        }
        reload()
    }

    /// 轻量提示：播报 + 顶部小气泡（不阻塞操作，可连续添加多个歌单）
    private func toast(_ message: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let label = UILabel()
        label.text = message
        label.font = Theme.bodyMedium
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = Theme.primaryDark
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.18, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.1, options: [], animations: {
                label.alpha = 0
            }, completion: { _ in
                label.removeFromSuperview()
            })
        }
    }
}

// MARK: - 列表

extension AddToPlaylistViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return playlists.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AddToPlaylistCell.reuseId, for: indexPath) as! AddToPlaylistCell
        let p = playlists[indexPath.row]
        cell.configure(name: p.name, count: p.songs.count, added: addedIds.contains(p.id))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        toggle(at: indexPath.row)
    }
}

// MARK: - 歌单行

final class AddToPlaylistCell: UITableViewCell {

    static let reuseId = "AddToPlaylistCell"

    private let card = UIView()
    private let iconWrap = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let checkView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.layer.cornerRadius = 14
        card.layer.borderWidth = 0.5

        iconWrap.layer.cornerRadius = 10

        iconView.image = UIImage(systemName: "music.note.list")
        iconView.contentMode = .scaleAspectFit

        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail

        countLabel.font = Theme.bodySmall

        checkView.image = UIImage(systemName: "checkmark.circle.fill")
        checkView.contentMode = .scaleAspectFit
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let textStack = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.alignment = .leading

        card.addSubview(iconWrap)
        iconWrap.addSubview(iconView)
        card.addSubview(textStack)
        card.addSubview(checkView)
        contentView.addSubview(card)

        card.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            iconWrap.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            iconWrap.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconWrap.widthAnchor.constraint(equalToConstant: 36),
            iconWrap.heightAnchor.constraint(equalToConstant: 36),

            iconView.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: iconWrap.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -10),

            checkView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            checkView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, count: Int, added: Bool) {
        // 主题可在运行中切换，逐次刷新颜色
        card.backgroundColor = added ? Theme.primaryContainer : Theme.cardBg
        card.layer.borderColor = (added ? Theme.primary : Theme.border).cgColor
        iconWrap.backgroundColor = added ? Theme.primary : Theme.searchFieldBg
        iconView.tintColor = added ? Theme.onPrimary : Theme.subtext
        nameLabel.textColor = Theme.text
        countLabel.textColor = Theme.subtext
        checkView.tintColor = Theme.primary
        checkView.isHidden = !added

        nameLabel.text = name
        countLabel.text = count > 0 ? "\(count) 首" : "空歌单"
    }
}
