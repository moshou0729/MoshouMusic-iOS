import UIKit

/// 迷你播放条 — 底部固定，显示当前播放歌曲和简单控制
class MiniPlayerBar: UIView {

    var onTap: (() -> Void)?

    private let containerView = UIView()
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)

    private var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        bindPlayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        bindPlayer()
    }

    // MARK: - UI

    private func setupUI() {
        backgroundColor = .clear

        // 容器
        containerView.backgroundColor = Theme.cardBg
        containerView.layer.cornerRadius = Theme.cornerMedium
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.08
        containerView.layer.shadowOffset = CGSize(width: 0, height: -2)
        containerView.layer.shadowRadius = 8
        addSubview(containerView)

        // 封面
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = Theme.cornerSmall
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = Theme.surfaceVariant
        artworkImageView.image = UIImage(systemName: "music.note")?
            .withTintColor(Theme.primary, renderingMode: .alwaysOriginal)
        containerView.addSubview(artworkImageView)

        // 标题
        titleLabel.font = Theme.bodyLarge
        titleLabel.textColor = Theme.text
        titleLabel.text = "墨守music"
        containerView.addSubview(titleLabel)

        // 歌手
        artistLabel.font = Theme.bodySmall
        artistLabel.textColor = Theme.subtext
        artistLabel.text = "准备就绪"
        containerView.addSubview(artistLabel)

        // 播放按钮
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = Theme.primary
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        containerView.addSubview(playButton)

        // 下一首
        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        nextButton.tintColor = Theme.text
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        containerView.addSubview(nextButton)

        // 进度条
        progressView.progressTintColor = Theme.primary
        progressView.trackTintColor = Theme.outlineVariant
        progressView.progress = 0
        containerView.addSubview(progressView)

        // 手势
        let tap = UITapGestureRecognizer(target: self, action: #selector(barTapped))
        containerView.addGestureRecognizer(tap)

        setupConstraints()
    }

    private func setupConstraints() {
        [containerView, artworkImageView, titleLabel, artistLabel,
         playButton, nextButton, progressView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 容器
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            // 封面
            artworkImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            artworkImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 44),
            artworkImageView.heightAnchor.constraint(equalToConstant: 44),

            // 播放按钮
            playButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            playButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),

            // 下一首
            nextButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            nextButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 36),
            nextButton.heightAnchor.constraint(equalToConstant: 36),

            // 标题
            titleLabel.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),

            // 歌手
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            // 进度条
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    // MARK: - 绑定播放器

    private func bindPlayer() {
        PlayerManager.shared.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateUI(state: state)
            }
        }

        PlayerManager.shared.onTimeChanged = { [weak self] current, duration in
            DispatchQueue.main.async {
                guard duration > 0 else { return }
                self?.progressView.setProgress(Float(current / duration), animated: true)
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkLoaded(_:)),
            name: .artworkLoaded, object: nil
        )
    }

    private func updateUI(state: PlayerState) {
        if let song = state.currentSong {
            titleLabel.text = song.name
            artistLabel.text = "\(song.singer) · \(Theme.sourceName(state.currentSource))"
        }

        isPlaying = state.isPlaying
        playButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
    }

    // MARK: - Actions

    @objc private func barTapped() {
        onTap?()
    }

    @objc private func playTapped() {
        PlayerManager.shared.togglePlayPause()
    }

    @objc private func nextTapped() {
        PlayerManager.shared.next()
    }

    @objc private func artworkLoaded(_ notification: Notification) {
        if let image = notification.object as? UIImage {
            artworkImageView.image = image
        }
    }
}
