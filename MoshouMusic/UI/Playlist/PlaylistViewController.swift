import UIKit

/// 歌单页 — 我的列表管理
class PlaylistViewController: UIViewController {

    private let tableView = UITableView()
    private let emptyLabel = UILabel()
    private let fabButton = UIButton(type: .system)

    private var playlists: [Playlist] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadPlaylists()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadPlaylists()
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

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            fabButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fabButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            fabButton.widthAnchor.constraint(equalToConstant: 56),
            fabButton.heightAnchor.constraint(equalToConstant: 56),
        ])
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

    private let playlist: Playlist
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
