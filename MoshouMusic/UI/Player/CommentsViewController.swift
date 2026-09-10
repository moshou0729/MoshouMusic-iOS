import UIKit

/// v1.0.141：歌曲评论页 —— 热门评论置顶 + 最新评论，Material 风格卡片，
/// 下拉刷新 / 滚到底自动加载更多。
final class CommentsViewController: UIViewController {

    private let song: Song

    private var comments: [SongComment] = []
    private var total = 0
    private var nextOffset = 0
    private var loading = false
    private var reachedEnd = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let statusLabel = UILabel()
    private let headerView = UIView()
    private let headerTitle = UILabel()
    private let footerSpinner = UIActivityIndicatorView(style: .medium)

    init(song: Song) {
        self.song = song
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "评论"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        setupUI()
        load(reset: true)
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    // MARK: - UI

    private func setupUI() {
        headerView.backgroundColor = Theme.bg
        headerTitle.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        headerTitle.textColor = .label
        headerTitle.numberOfLines = 1
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.text = song.name
        headerView.addSubview(headerTitle)

        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在加载评论…"

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CommentCell.self, forCellReuseIdentifier: CommentCell.reuseId)
        tableView.backgroundColor = Theme.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        headerView.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 42)
        tableView.tableHeaderView = headerView
        refreshControl.tintColor = Theme.primary
        refreshControl.addTarget(self, action: #selector(pulled), for: .valueChanged)
        tableView.refreshControl = refreshControl

        footerSpinner.hidesWhenStopped = true
        footerSpinner.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 36)
        tableView.tableFooterView = footerSpinner

        view.addSubview(tableView)
        view.addSubview(statusLabel)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            headerTitle.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            headerTitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            headerTitle.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            headerTitle.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - 加载

    @objc private func pulled() {
        load(reset: true)
    }

    private func load(reset: Bool) {
        guard !loading else { return }
        loading = true
        if reset {
            reachedEnd = false
            statusLabel.text = "正在加载评论…"
            statusLabel.isHidden = false
            nextOffset = 0
        } else {
            footerSpinner.startAnimating()
        }
        CommentService.shared.fetchComments(for: song, offset: nextOffset) { [weak self] result in
            guard let self = self else { return }
            self.loading = false
            self.refreshControl.endRefreshing()
            self.footerSpinner.stopAnimating()
            switch result {
            case .failure(let error):
                if self.comments.isEmpty {
                    self.statusLabel.text = (error as NSError).userInfo[NSLocalizedDescriptionKey]
                        as? String ?? "评论加载失败，下拉重试"
                    self.statusLabel.isHidden = false
                } else {
                    self.statusLabel.text = "加载更多失败"
                    self.statusLabel.isHidden = true
                }
            case .success(let payload):
                self.total = payload.total
                if reset {
                    self.comments = payload.comments
                } else {
                    // 分页可能重复返回热门评论，按内容去重
                    let seen = Set(self.comments.map { $0.content + $0.nickname })
                    self.comments += payload.comments.filter { !seen.contains($0.content + $0.nickname) }
                }
                self.nextOffset = self.comments.count
                self.reachedEnd = self.comments.count >= max(self.total, 1) || payload.comments.isEmpty
                self.headerTitle.text = "\(self.song.name) · \(self.total) 条评论"
                self.statusLabel.isHidden = !self.comments.isEmpty
                if self.comments.isEmpty {
                    self.statusLabel.text = "这首歌还没有评论"
                }
                self.tableView.reloadData()
            }
        }
    }
}

// MARK: - UITableViewDataSource / Delegate

extension CommentsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return comments.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CommentCell.reuseId, for: indexPath) as! CommentCell
        cell.configure(with: comments[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 滚到最后 6 条内自动加载更多
        if !loading, !reachedEnd, indexPath.row >= comments.count - 6 {
            load(reset: false)
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard !comments.contains(where: { $0.isHot }) else { return nil }
        return nil
    }
}

// MARK: - 评论 Cell

final class CommentCell: UITableViewCell {

    static let reuseId = "CommentCell"

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let contentLabel = UILabel()
    private let metaLabel = UILabel()

    /// 当前展示的头像 URL（复用时比对，避免异步回填错位）
    private var currentAvatar: URL?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = Theme.bg

        avatarView.contentMode = .scaleAspectFill
        avatarView.layer.cornerRadius = 19
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = UIColor(hex: 0x2A2545)
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)

        nameLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.primary

        contentLabel.font = UIFont.systemFont(ofSize: 15)
        contentLabel.textColor = .label
        contentLabel.numberOfLines = 0

        metaLabel.font = UIFont.systemFont(ofSize: 12)
        metaLabel.textColor = .tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [nameLabel, contentLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(8, after: contentLabel)

        contentView.addSubview(avatarView)
        contentView.addSubview(stack)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatarView.widthAnchor.constraint(equalToConstant: 38),
            avatarView.heightAnchor.constraint(equalToConstant: 38),

            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 70),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with comment: SongComment) {
        nameLabel.text = comment.isHot ? "🔥 \(comment.nickname)" : comment.nickname
        contentLabel.text = comment.content
        metaLabel.text = {
            var parts: [String] = []
            if !comment.timeText.isEmpty { parts.append(comment.timeText) }
            if comment.likes > 0 { parts.append("♥ \(comment.likes)") }
            return parts.joined(separator: "  ·  ")
        }()
        currentAvatar = comment.avatarURL
        guard let url = comment.avatarURL else {
            avatarView.image = UIImage(systemName: "person.crop.circle.fill")?
                .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
            return
        }
        CommentService.shared.loadImage(url) { [weak self] img in
            guard let self = self, self.currentAvatar == url else { return }
            self.avatarView.image = img ?? self.avatarView.image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAvatar = nil
        contentLabel.text = nil
    }
}
