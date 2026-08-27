import UIKit

/// 歌单搜索结果项 — Material Design 3 风格
/// 封面 + 歌单名 + 「来源 / 曲目数 / 创建者」
class PlaylistSearchCell: UITableViewCell {

    static let reuseIdentifier = "PlaylistSearchCell"

    private let containerView = UIView()
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let sourceTag = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - UI

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear

        contentView.addSubview(containerView)
        containerView.addSubview(artworkImageView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(subtitleLabel)
        containerView.addSubview(sourceTag)

        containerView.layer.cornerRadius = Theme.cornerMedium
        containerView.backgroundColor = Theme.cardBg

        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = Theme.cornerSmall
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = Theme.surfaceVariant
        artworkImageView.image = UIImage(systemName: "music.note.list")?
            .withTintColor(Theme.primary, renderingMode: .alwaysOriginal)

        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 1

        subtitleLabel.font = Theme.bodySmall
        subtitleLabel.textColor = Theme.subtext
        subtitleLabel.numberOfLines = 1

        sourceTag.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        sourceTag.textColor = .white
        sourceTag.textAlignment = .center
        sourceTag.layer.cornerRadius = 4
        sourceTag.layer.masksToBounds = true

        setupConstraints()
    }

    private func setupConstraints() {
        [containerView, artworkImageView, titleLabel, subtitleLabel, sourceTag].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

            artworkImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            artworkImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 48),
            artworkImageView.heightAnchor.constraint(equalToConstant: 48),

            sourceTag.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            sourceTag.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            sourceTag.heightAnchor.constraint(equalToConstant: 18),
            sourceTag.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: sourceTag.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - 配置

    func configure(with pl: SearchedPlaylist, index: Int) {
        titleLabel.text = pl.name

        let countText = pl.trackCount > 0 ? "\(pl.trackCount) 首" : "歌单"
        let creatorText = pl.creator.isEmpty ? "" : " · \(pl.creator)"
        subtitleLabel.text = "\(countText)\(creatorText)"

        let name = ConfigStore.shared.displayName(for: pl.source)
        sourceTag.text = " \(name) "
        sourceTag.backgroundColor = Theme.sourceColor(pl.source)

        containerView.backgroundColor = index % 2 == 0 ? Theme.cardBg : Theme.surfaceVariant

        if let url = pl.coverUrl, let u = URL(string: url) {
            NetworkManager.shared.loadImage(url: u.absoluteString) { [weak self] data in
                if let data = data, let img = UIImage(data: data) {
                    self?.artworkImageView.image = img
                }
            }
        }
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.15) {
            self.containerView.backgroundColor = highlighted ? Theme.primaryContainer : Theme.cardBg
        }
    }
}
