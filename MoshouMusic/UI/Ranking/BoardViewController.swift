import UIKit

/// 排行榜 / 推荐详情页 — 拉取指定音源的 musicBoard 并展示真实歌曲
class BoardViewController: UIViewController {

    private let tableView = UITableView()
    private let emptyLabel = UILabel()
    private let source: String

    private var songs: [Song] = []

    init(source: String) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
        self.title = ConfigStore.shared.displayName(for: source) + " · 推荐"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadBoard()
    }

    private func setupUI() {
        view.backgroundColor = Theme.bg

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongCell.self, forCellReuseIdentifier: SongCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 68
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "加载中..."
        emptyLabel.font = Theme.bodyLarge
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        view.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func loadBoard() {
        emptyLabel.text = "加载中..."
        emptyLabel.isHidden = false

        ScriptEngine.shared.musicBoard(source: source) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let list):
                    self.songs = list.compactMap { Song(from: $0, source: self.source) }
                    self.tableView.reloadData()
                    if self.songs.isEmpty {
                        self.emptyLabel.text = "暂无推荐内容"
                        self.emptyLabel.isHidden = false
                    } else {
                        self.emptyLabel.isHidden = true
                    }
                case .failure(let error):
                    Logger.error("榜单加载失败: \(error.localizedDescription)")
                    self.emptyLabel.text = "加载失败，请检查音源脚本"
                    self.emptyLabel.isHidden = false
                }
            }
        }
    }
}

extension BoardViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return songs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SongCell.reuseIdentifier, for: indexPath) as! SongCell
        let song = songs[indexPath.row]
        cell.configure(with: song, index: indexPath.row)
        cell.onMoreTapped = { [weak self] song in
            self?.showMoreOptions(for: song)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let song = songs[indexPath.row]
        PlayerManager.shared.play(song: song, queue: songs)
    }

    private func showMoreOptions(for song: Song) {
        let alert = UIAlertController(title: song.name, message: song.singer, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "添加到歌单", style: .default) { _ in
            let picker = UIAlertController(title: "选择歌单", message: nil, preferredStyle: .actionSheet)
            for playlist in PlaylistStore.shared.playlists {
                picker.addAction(UIAlertAction(title: playlist.name, style: .default) { _ in
                    PlaylistStore.shared.addSong(song, to: playlist.id)
                })
            }
            picker.addAction(UIAlertAction(title: "新建歌单", style: .default) { _ in
                let dialog = UIAlertController(title: "新建歌单", message: nil, preferredStyle: .alert)
                dialog.addTextField { $0.placeholder = "歌单名称" }
                dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
                dialog.addAction(UIAlertAction(title: "创建", style: .default) { _ in
                    if let name = dialog.textFields?.first?.text, !name.isEmpty {
                        let p = PlaylistStore.shared.create(name: name)
                        PlaylistStore.shared.addSong(song, to: p.id)
                    }
                })
                self.present(dialog, animated: true)
            })
            picker.addAction(UIAlertAction(title: "取消", style: .cancel))
            self.present(picker, animated: true)
        })
        alert.addAction(UIAlertAction(title: "下一首播放", style: .default) { _ in
            PlayerManager.shared.addToQueue(song)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        self.present(alert, animated: true)
    }
}
