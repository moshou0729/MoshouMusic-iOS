import UIKit

/// 歌曲列表项 — Material Design 3 风格
/// 交替背景色 + 音源颜色标识 + 更多操作按钮
class SongCell: UITableViewCell {

    static let reuseIdentifier = "SongCell"

    private let containerView = UIView()
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let sourceTag = UILabel()
    private let durationLabel = UILabel()
    private let moreButton = UIButton(type: .system)

    var onMoreTapped: ((Song) -> Void)?

    private var song: Song?

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
        containerView.addSubview(artistLabel)
        containerView.addSubview(sourceTag)
        containerView.addSubview(durationLabel)
        containerView.addSubview(moreButton)

        // 容器
        containerView.layer.cornerRadius = Theme.cornerMedium
        containerView.backgroundColor = Theme.cardBg

        // 封面
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = Theme.cornerSmall
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = Theme.surfaceVariant
        artworkImageView.image = UIImage(systemName: "music.note")?
            .withTintColor(Theme.primary, renderingMode: .alwaysOriginal)

        // 标题
        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 1

        // 歌手
        artistLabel.font = Theme.bodySmall
        artistLabel.textColor = Theme.subtext
        artistLabel.numberOfLines = 1

        // 源标签
        sourceTag.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        sourceTag.textColor = .white
        sourceTag.textAlignment = .center
        sourceTag.layer.cornerRadius = 4
        sourceTag.layer.masksToBounds = true

        // 时长
        durationLabel.font = Theme.bodySmall
        durationLabel.textColor = Theme.subtext
        durationLabel.textAlignment = .right

        // 更多按钮
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = Theme.subtext
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)

        setupConstraints()
    }

    private func setupConstraints() {
        [containerView, artworkImageView, titleLabel, artistLabel,
         sourceTag, durationLabel, moreButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 容器
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

            // 封面
            artworkImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            artworkImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 48),
            artworkImageView.heightAnchor.constraint(equalToConstant: 48),
            artworkImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            artworkImageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),

            // 更多按钮
            moreButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 32),
            moreButton.heightAnchor.constraint(equalToConstant: 32),

            // 时长
            durationLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -8),
            durationLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 40),

            // 源标签
            sourceTag.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            sourceTag.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            sourceTag.heightAnchor.constraint(equalToConstant: 18),
            sourceTag.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            // 标题
            titleLabel.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: sourceTag.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),

            // 歌手
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - 配置

    func configure(with song: Song, index: Int) {
        self.song = song

        titleLabel.text = song.name
        artistLabel.text = song.singer

        // 源标签
        sourceTag.text = " \(Theme.sourceName(song.source)) "
        sourceTag.backgroundColor = Theme.sourceColor(song.source)

        // 时长
        if song.interval > 0 {
            let min = song.interval / 60
            let sec = song.interval % 60
            durationLabel.text = String(format: "%d:%02d", min, sec)
        } else {
            durationLabel.text = ""
        }

        // 交替背景色
        containerView.backgroundColor = index % 2 == 0
            ? Theme.cardBg
            : Theme.surfaceVariant

        // 加载封面
        if let imgUrl = song.imgUrl, let url = URL(string: imgUrl) {
            loadImage(url: url)
        }
    }

    private func loadImage(url: URL) {
        NetworkManager.shared.loadImage(url: url.absoluteString) { [weak self] data in
            if let data = data, let image = UIImage(data: data) {
                self?.artworkImageView.image = image
            }
        }
    }

    // MARK: - 交替背景

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.15) {
            self.containerView.backgroundColor = highlighted
                ? Theme.primaryContainer
                : self.song.map { Theme.cardBg } ?? Theme.cardBg
        }
    }

    // MARK: - Actions

    @objc private func moreTapped() {
        guard let song = song else { return }
        onMoreTapped?(song)
    }
}
