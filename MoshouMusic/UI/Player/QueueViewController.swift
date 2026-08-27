import UIKit

/// 当前播放队列页 — 查看/跳转/删除/重排 播放清单
class QueueViewController: UIViewController {

    private let tableView = UITableView()
    private let emptyLabel = UILabel()

    private var queue: [Song] = []
    private var currentIndex: Int = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(queueChanged),
            name: .playerQueueChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .playerStateChanged, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = Theme.bg
        title = "播放队列"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成", style: .done, target: self, action: #selector(doneTapped)
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(QueueCell.self, forCellReuseIdentifier: QueueCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelectionDuringEditing = false
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyLabel.text = "暂无播放队列"
        emptyLabel.font = Theme.bodyLarge
        emptyLabel.textColor = Theme.subtext
        emptyLabel.textAlignment = .center
        view.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 数据

    private func reload() {
        queue = PlayerManager.shared.currentQueue
        currentIndex = PlayerManager.shared.currentQueueIndex
        tableView.reloadData()
        emptyLabel.isHidden = !queue.isEmpty
        title = queue.isEmpty ? "播放队列" : "播放队列 · \(queue.count) 首"
    }

    @objc private func queueChanged() { reload() }
    @objc private func stateChanged() { reload() }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }
}

// MARK: - Table

extension QueueViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return queue.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueCell.reuseIdentifier, for: indexPath) as! QueueCell
        let song = queue[indexPath.row]
        cell.configure(song: song, index: indexPath.row, isCurrent: indexPath.row == currentIndex)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // 跳转到队列中的这一首（保持当前队列顺序）
        PlayerManager.shared.play(song: queue[indexPath.row], queue: queue)
        currentIndex = indexPath.row
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "移除") { _, _, completion in
            PlayerManager.shared.removeFromQueue(at: indexPath.row)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // 编辑模式：重排
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return queue.count > 1
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        PlayerManager.shared.moveQueueItem(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }
}

// MARK: - QueueCell

class QueueCell: UITableViewCell {

    static let reuseIdentifier = "QueueCell"

    private let containerView = UIView()
    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let sourceBar = UIView()

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

        sourceBar.backgroundColor = Theme.primary
        sourceBar.layer.cornerRadius = 2
        containerView.addSubview(sourceBar)

        indexLabel.font = Theme.bodyMedium
        indexLabel.textColor = Theme.subtext
        indexLabel.textAlignment = .center
        containerView.addSubview(indexLabel)

        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 1
        containerView.addSubview(titleLabel)

        artistLabel.font = Theme.bodySmall
        artistLabel.textColor = Theme.subtext
        artistLabel.numberOfLines = 1
        containerView.addSubview(artistLabel)

        [containerView, sourceBar, indexLabel, titleLabel, artistLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            sourceBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
            sourceBar.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            sourceBar.widthAnchor.constraint(equalToConstant: 3),
            sourceBar.heightAnchor.constraint(equalTo: containerView.heightAnchor, constant: -16),

            indexLabel.leadingAnchor.constraint(equalTo: sourceBar.trailingAnchor, constant: 8),
            indexLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(song: Song, index: Int, isCurrent: Bool) {
        titleLabel.text = song.name
        artistLabel.text = song.singer
        indexLabel.text = isCurrent ? "▶" : "\(index + 1)"
        indexLabel.textColor = isCurrent ? Theme.primary : Theme.subtext
        titleLabel.textColor = isCurrent ? Theme.primary : Theme.text
        sourceBar.backgroundColor = Theme.sourceColor(song.source)
        containerView.backgroundColor = isCurrent ? Theme.primaryContainer : Theme.cardBg
    }
}
