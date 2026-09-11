import UIKit

/// v1.0.141：歌曲评论页
/// v1.0.148：Material 3 卡片化改版 —— 歌曲信息头卡 + 评论卡片（头像 / 昵称 / 热评徽章 /
/// 内容 / 时间·点赞行），空态与加载态统一到居中的状态块。
final class CommentsViewController: UIViewController {

    private let song: Song

    private var comments: [SongComment] = []
    private var total = 0
    private var nextOffset = 0
    private var loading = false
    private var reachedEnd = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let headerView = UIView()
    private let headerTitle = UILabel()
    private let headerSub = UILabel()
    private let footerSpinner = UIActivityIndicatorView(style: .medium)

    // 状态块（加载中 / 空 / 失败）
    private let statusStack = UIStackView()
    private let statusIcon = UIImageView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

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
        // ---- 歌曲信息头卡 ----
        headerView.backgroundColor = .clear
        let headCard = UIView()
        headCard.translatesAutoresizingMaskIntoConstraints = false
        headCard.backgroundColor = Theme.cardBg
        headCard.layer.cornerRadius = 16
        headCard.layer.borderWidth = 0.5
        headCard.layer.borderColor = Theme.border.cgColor
        headerView.addSubview(headCard)

        // 主色竖条装饰
        let accent = UIView()
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.backgroundColor = Theme.primary
        accent.layer.cornerRadius = 2
        headCard.addSubview(accent)

        headerTitle.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        headerTitle.textColor = Theme.text
        headerTitle.numberOfLines = 1
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.text = song.name

        headerSub.font = UIFont.systemFont(ofSize: 13)
        headerSub.textColor = Theme.subtext
        headerSub.numberOfLines = 1
        headerSub.lineBreakMode = .byTruncatingTail
        headerSub.text = song.singer

        headCard.addSubview(headerTitle)
        headCard.addSubview(headerSub)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerSub.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headCard.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 4),
            headCard.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            headCard.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            headCard.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -6),

            accent.leadingAnchor.constraint(equalTo: headCard.leadingAnchor, constant: 14),
            accent.centerYAnchor.constraint(equalTo: headCard.centerYAnchor),
            accent.widthAnchor.constraint(equalToConstant: 4),
            accent.heightAnchor.constraint(equalToConstant: 30),

            headerTitle.topAnchor.constraint(equalTo: headCard.topAnchor, constant: 13),
            headerTitle.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 12),
            headerTitle.trailingAnchor.constraint(equalTo: headCard.trailingAnchor, constant: -14),

            headerSub.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 4),
            headerSub.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            headerSub.trailingAnchor.constraint(equalTo: headerTitle.trailingAnchor),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 72)

        // ---- 状态块 ----
        statusIcon.image = UIImage(systemName: "bubble.left.and.bubble.right")
        statusIcon.tintColor = Theme.border
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        statusIcon.isHidden = true

        statusSpinner.color = Theme.primary
        statusSpinner.hidesWhenStopped = false

        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = Theme.subtext
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在加载评论…"

        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 10
        statusStack.addArrangedSubview(statusSpinner)
        statusStack.addArrangedSubview(statusIcon)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        // ---- 表格 ----
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CommentCell.self, forCellReuseIdentifier: CommentCell.reuseId)
        tableView.backgroundColor = Theme.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 132
        tableView.tableHeaderView = headerView
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 16, right: 0)
        tableView.showsVerticalScrollIndicator = false
        refreshControl.tintColor = Theme.primary
        refreshControl.addTarget(self, action: #selector(pulled), for: .valueChanged)
        tableView.refreshControl = refreshControl

        footerSpinner.hidesWhenStopped = true
        footerSpinner.color = Theme.primary
        footerSpinner.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 40)
        tableView.tableFooterView = footerSpinner

        view.addSubview(tableView)
        view.addSubview(statusStack)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 36),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -36),
        ])
    }

    /// 状态块展示：loading = 转圈，其它 = 图标 + 文案
    private func showStatus(text: String, loading: Bool, icon: String?) {
        statusLabel.text = text
        statusSpinner.isHidden = !loading
        if loading { statusSpinner.startAnimating() } else { statusSpinner.stopAnimating() }
        statusIcon.isHidden = loading || icon == nil
        if let icon = icon { statusIcon.image = UIImage(systemName: icon) }
        statusStack.isHidden = false
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
            nextOffset = 0
        }
        let isEmptyFirstLoad = reset && comments.isEmpty
        if isEmptyFirstLoad {
            showStatus(text: "正在加载评论…", loading: true, icon: nil)
            tableView.isHidden = true
        } else if !reset {
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
                    let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? "评论加载失败，下拉重试"
                    self.showStatus(text: msg, loading: false, icon: "wifi.exclamationmark")
                    self.tableView.isHidden = true
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
                self.headerSub.text = "\(self.song.singer)  ·  \(self.total) 条评论"
                if self.comments.isEmpty {
                    self.showStatus(text: "还没有人评论，来说点什么吧", loading: false, icon: "bubble.left.and.bubble.right")
                    self.tableView.isHidden = true
                } else {
                    self.statusStack.isHidden = true
                    self.tableView.isHidden = false
                    self.tableView.reloadData()
                }
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
}

// MARK: - 带内边距的徽章标签

/// 小徽章（热评）：文字自带宽高，圆角由调用方设置
final class CmtBadgeLabel: UILabel {

    var insets = UIEdgeInsets(top: 1.5, left: 6, bottom: 1.5, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}

// MARK: - 评论 Cell（Material 卡片）

final class CommentCell: UITableViewCell {

    static let reuseId = "CommentCell"

    private let card = UIView()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let hotBadge = CmtBadgeLabel()
    private let contentLabel = UILabel()
    private let metaLabel = UILabel()
    private let likeIcon = UIImageView()
    private let likeLabel = UILabel()

    /// 当前展示的头像 URL（复用时比对，避免异步回填错位）
    private var currentAvatar: URL?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.layer.cornerRadius = 16
        card.layer.borderWidth = 0.5

        avatarView.contentMode = .scaleAspectFill
        avatarView.layer.cornerRadius = 20
        avatarView.clipsToBounds = true
        avatarView.layer.borderWidth = 0.5
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)

        nameLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hotBadge.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        hotBadge.text = "热评"
        hotBadge.layer.cornerRadius = 4
        hotBadge.clipsToBounds = true
        hotBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        hotBadge.setContentHuggingPriority(.required, for: .horizontal)

        contentLabel.font = UIFont.systemFont(ofSize: 15)
        contentLabel.numberOfLines = 0

        metaLabel.font = UIFont.systemFont(ofSize: 12)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        likeIcon.image = UIImage(systemName: "heart.fill")
        likeIcon.contentMode = .scaleAspectFit
        likeIcon.translatesAutoresizingMaskIntoConstraints = false
        likeIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        likeIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        likeLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        likeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // 昵称 + 热评徽章：放 stack 里，徽章隐藏时自动不占位
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, hotBadge])
        nameRow.axis = .horizontal
        nameRow.spacing = 6
        nameRow.alignment = .center

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomRow = UIStackView(arrangedSubviews: [metaLabel, spacer, likeIcon, likeLabel])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 5
        bottomRow.alignment = .center

        card.addSubview(avatarView)
        card.addSubview(nameRow)
        card.addSubview(contentLabel)
        card.addSubview(bottomRow)
        contentView.addSubview(card)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            avatarView.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            avatarView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),

            nameRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            nameRow.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            nameRow.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),

            contentLabel.topAnchor.constraint(equalTo: nameRow.bottomAnchor, constant: 8),
            contentLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            bottomRow.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 10),
            bottomRow.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            bottomRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with comment: SongComment) {
        // 主题可能是运行中切换的，逐次刷新颜色
        card.backgroundColor = Theme.cardBg
        card.layer.borderColor = Theme.border.cgColor
        avatarView.backgroundColor = Theme.searchFieldBg
        avatarView.layer.borderColor = Theme.border.cgColor
        nameLabel.textColor = Theme.text
        contentLabel.textColor = Theme.text
        metaLabel.textColor = Theme.subtext
        likeLabel.textColor = Theme.subtext
        likeIcon.tintColor = comment.likes > 0 ? Theme.secondary : Theme.border
        hotBadge.textColor = Theme.primaryDark
        hotBadge.backgroundColor = Theme.primaryContainer

        nameLabel.text = comment.nickname
        hotBadge.isHidden = !comment.isHot

        // 行距 4，长评论更透气
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        contentLabel.attributedText = NSAttributedString(
            string: comment.content,
            attributes: [.paragraphStyle: para,
                         .font: UIFont.systemFont(ofSize: 15),
                         .foregroundColor: Theme.text])

        metaLabel.text = comment.timeText.isEmpty ? "刚刚" : comment.timeText
        if comment.likes > 0 {
            likeIcon.isHidden = false
            likeLabel.isHidden = false
            likeLabel.text = comment.likes > 9999
                ? String(format: "%.1fw", Double(comment.likes) / 10000.0)
                : "\(comment.likes)"
        } else {
            likeIcon.isHidden = true
            likeLabel.isHidden = true
            likeLabel.text = nil
        }

        currentAvatar = comment.avatarURL
        let placeholder = UIImage(systemName: "person.crop.circle.fill")?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        guard let url = comment.avatarURL else {
            avatarView.image = placeholder
            return
        }
        avatarView.image = placeholder
        CommentService.shared.loadImage(url) { [weak self] img in
            guard let self = self, self.currentAvatar == url, let img = img else { return }
            self.avatarView.image = img
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAvatar = nil
        contentLabel.text = nil
        contentLabel.attributedText = nil
        avatarView.image = nil
    }
}
