import UIKit

/// 播放页 — 全屏沉浸式播放界面
/// 深色背景 + 大圆角封面 + 歌词滚动 + 播放控制
class PlayerViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let backgroundView = UIView()
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let lyricsScrollView = UIScrollView()
    private let lyricsLabel = UILabel()
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let playModeButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let sourceLabel = UILabel()
    private let errorLabel = UILabel()

    private var currentArtworkImage: UIImage?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindPlayer()
        updateUI()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .black

        // 背景
        backgroundView.backgroundColor = UIColor(hex: 0x1A1535)
        view.addSubview(backgroundView)

        // 关闭按钮
        closeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // 源标签（可点击 → 手动换源）
        sourceLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        sourceLabel.textColor = .white
        sourceLabel.alpha = 0.6
        sourceLabel.isUserInteractionEnabled = true
        sourceLabel.textAlignment = .right
        // 扩大点击热区，11pt 文字直接点很难命中
        let sourceTap = UITapGestureRecognizer(target: self, action: #selector(sourceTapped))
        sourceLabel.addGestureRecognizer(sourceTap)
        view.addSubview(sourceLabel)

        // 错误提示条（播放失败时显示具体原因，便于排查是哪个源/哪一步失败）
        errorLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        errorLabel.textColor = UIColor(hex: 0xFF8A80)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        view.addSubview(errorLabel)

        // 封面
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = Theme.cornerLarge
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = UIColor(hex: 0x2A2545)
        artworkImageView.image = UIImage(systemName: "music.note")?
            .withTintColor(.white.withAlphaComponent(0.3), renderingMode: .alwaysOriginal)
        view.addSubview(artworkImageView)

        // 标题
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        view.addSubview(titleLabel)

        // 歌手
        artistLabel.font = Theme.bodyMedium
        artistLabel.textColor = .white.withAlphaComponent(0.6)
        artistLabel.numberOfLines = 1
        view.addSubview(artistLabel)

        // 歌词
        lyricsScrollView.isPagingEnabled = false
        lyricsScrollView.showsVerticalScrollIndicator = false
        lyricsScrollView.backgroundColor = .clear
        view.addSubview(lyricsScrollView)

        lyricsLabel.numberOfLines = 0
        lyricsLabel.textAlignment = .center
        lyricsLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        lyricsLabel.textColor = .white.withAlphaComponent(0.4)
        lyricsScrollView.addSubview(lyricsLabel)

        // 进度条
        progressSlider.minimumTrackTintColor = Theme.primaryLight
        progressSlider.maximumTrackTintColor = .white.withAlphaComponent(0.2)
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        view.addSubview(progressSlider)

        // 时间
        currentTimeLabel.font = Theme.bodySmall
        currentTimeLabel.textColor = .white.withAlphaComponent(0.5)
        currentTimeLabel.text = "0:00"
        view.addSubview(currentTimeLabel)

        durationLabel.font = Theme.bodySmall
        durationLabel.textColor = .white.withAlphaComponent(0.5)
        durationLabel.text = "0:00"
        durationLabel.textAlignment = .right
        view.addSubview(durationLabel)

        // 控制按钮
        playModeButton.tintColor = .white.withAlphaComponent(0.7)
        playModeButton.addTarget(self, action: #selector(playModeTapped), for: .touchUpInside)

        previousButton.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        previousButton.tintColor = .white
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        nextButton.tintColor = .white
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        [playModeButton, previousButton, playButton, nextButton].forEach {
            view.addSubview($0)
        }

        setupConstraints()
    }

    private func setupConstraints() {
        let allViews: [UIView] = [backgroundView, closeButton, sourceLabel, errorLabel, artworkImageView,
                                   titleLabel, artistLabel, lyricsScrollView, lyricsLabel,
                                   progressSlider, currentTimeLabel, durationLabel,
                                   playModeButton, previousButton, playButton, nextButton]
        allViews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let screenWidth = UIScreen.main.bounds.width
        let artworkSize = screenWidth - 80

        NSLayoutConstraint.activate([
            // 背景
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 关闭
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            // 源标签（高度 36 保证热区够大）
            sourceLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            sourceLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sourceLabel.heightAnchor.constraint(equalToConstant: 36),
            sourceLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            // 错误提示条
            errorLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // 封面
            artworkImageView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 20),
            artworkImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: artworkSize),
            artworkImageView.heightAnchor.constraint(equalToConstant: artworkSize),

            // 标题
            titleLabel.topAnchor.constraint(equalTo: artworkImageView.bottomAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            // 歌手
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            // 歌词
            lyricsScrollView.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 16),
            lyricsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            lyricsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            lyricsScrollView.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -16),

            lyricsLabel.topAnchor.constraint(equalTo: lyricsScrollView.topAnchor, constant: 20),
            lyricsLabel.leadingAnchor.constraint(equalTo: lyricsScrollView.leadingAnchor),
            lyricsLabel.trailingAnchor.constraint(equalTo: lyricsScrollView.trailingAnchor),
            lyricsLabel.widthAnchor.constraint(equalTo: lyricsScrollView.widthAnchor),
            lyricsLabel.bottomAnchor.constraint(equalTo: lyricsScrollView.bottomAnchor, constant: -20),

            // 进度条
            progressSlider.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: -24),
            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            progressSlider.heightAnchor.constraint(equalToConstant: 30),

            // 时间
            currentTimeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: -4),
            currentTimeLabel.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 50),

            durationLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: -4),
            durationLabel.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 50),

            // 控制
            playButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 72),
            playButton.heightAnchor.constraint(equalToConstant: 72),

            previousButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -40),
            previousButton.widthAnchor.constraint(equalToConstant: 48),
            previousButton.heightAnchor.constraint(equalToConstant: 48),

            nextButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 40),
            nextButton.widthAnchor.constraint(equalToConstant: 48),
            nextButton.heightAnchor.constraint(equalToConstant: 48),

            playModeButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            playModeButton.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -24),
            playModeButton.widthAnchor.constraint(equalToConstant: 36),
            playModeButton.heightAnchor.constraint(equalToConstant: 36),
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
                guard let self = self else { return }
                // duration 可能是 NaN（流媒体未知时长）：isFinite 检查必须放在比较之前，
                // 因为 NaN 参与的任何比较都返回 false，容易被误判成「有效」
                guard duration.isFinite, current.isFinite, duration > 0 else {
                    self.progressSlider.setValue(0, animated: false)
                    self.currentTimeLabel.text = self.formatTime(current)
                    self.durationLabel.text = "--:--"
                    return
                }
                let ratio = Float(min(max(current / duration, 0), 1))
                self.progressSlider.setValue(ratio, animated: false)
                self.currentTimeLabel.text = self.formatTime(current)
                self.durationLabel.text = self.formatTime(duration)
            }
        }

        PlayerManager.shared.onLyricsChanged = { [weak self] index, lines in
            DispatchQueue.main.async {
                self?.updateLyrics(index: index, lines: lines)
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkLoaded(_:)),
            name: .artworkLoaded, object: nil
        )
    }

    // MARK: - 更新 UI

    private func updateUI() {
        guard let song = PlayerManager.shared.currentSong else { return }
        titleLabel.text = song.name
        artistLabel.text = song.singer
        setSourceLabel(PlayerManager.shared.currentSource)
    }

    /// "酷我 ⇄" —— 带箭头暗示可点换源
    private func setSourceLabel(_ source: String) {
        sourceLabel.text = Theme.sourceName(source) + "  ⇄"
    }

    private func updateUI(state: PlayerState) {
        if let song = state.currentSong {
            titleLabel.text = song.name
            artistLabel.text = song.singer
            setSourceLabel(state.currentSource)

            // 背景颜色随音源变化
            UIView.animate(withDuration: 0.3) {
                self.backgroundView.backgroundColor = Theme.sourceColor(state.currentSource)
                    .mix(with: UIColor(hex: 0x1A1535), ratio: 0.7)
            }
        }

        // 播放按钮
        playButton.setImage(
            UIImage(systemName: state.isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )

        // 播放模式
        playModeButton.setImage(UIImage(systemName: state.playMode.iconName), for: .normal)

        // 错误提示
        if let err = PlayerManager.shared.lastPlayError, !state.isPlaying {
            errorLabel.text = "⚠️ \(err)"
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }

    private func updateLyrics(index: Int, lines: [LRCLine]) {
        if lines.isEmpty {
            lyricsLabel.text = "暂无歌词"
            return
        }

        // 拼接所有歌词，高亮当前行
        let attributed = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let isCurrent = i == index
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent
                    ? UIFont.systemFont(ofSize: 20, weight: .bold)
                    : UIFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: isCurrent
                    ? UIColor.white
                    : UIColor.white.withAlphaComponent(0.35)
            ]
            attributed.append(NSAttributedString(string: line.text, attributes: attrs))
            if i < lines.count - 1 {
                attributed.append(NSAttributedString(string: "\n\n"))
            }
        }
        lyricsLabel.attributedText = attributed

        // 滚动到当前行
        if index >= 0 && index < lines.count {
            let lineHeight: CGFloat = 40
            let offsetY = CGFloat(index) * lineHeight - lyricsScrollView.bounds.height / 2 + lineHeight / 2
            let maxOffset = lyricsLabel.bounds.height - lyricsScrollView.bounds.height
            let clampedOffset = max(0, min(offsetY, maxOffset))
            lyricsScrollView.setContentOffset(
                CGPoint(x: 0, y: clampedOffset),
                animated: true
            )
        }
    }

    @objc private func artworkLoaded(_ notification: Notification) {
        if let image = notification.object as? UIImage {
            currentArtworkImage = image
            artworkImageView.image = image
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func playTapped() {
        PlayerManager.shared.togglePlayPause()
    }

    @objc private func previousTapped() {
        PlayerManager.shared.previous()
    }

    @objc private func nextTapped() {
        PlayerManager.shared.next()
    }

    @objc private func playModeTapped() {
        PlayerManager.shared.togglePlayMode()
    }

    @objc private func sliderChanged() {
        let duration = PlayerManager.shared.duration
        // 总时长未知（NaN / 0）时拖动无意义，直接忽略；
        // 否则 NaN 会一路传到 AVPlayer.seek 并让 App 立刻闪退
        guard duration.isFinite, duration > 0 else {
            progressSlider.setValue(0, animated: false)
            return
        }
        let time = Double(progressSlider.value) * duration
        PlayerManager.shared.seek(to: time)
    }

    // MARK: - 手动换源

    /// 点顶部音源标签 → 选一个别的音源播同一首歌
    @objc private func sourceTapped() {
        guard PlayerManager.shared.currentSong != nil else { return }

        let current = PlayerManager.shared.currentSource
        // 候选：已启用 + 脚本已加载 + 不是当前源
        let candidates = ConfigStore.shared.selectableSourceIds.filter {
            $0 != current
                && ConfigStore.shared.isSourceEnabled($0)
                && ScriptEngine.shared.hasHandler(for: $0)
        }

        let sheet = UIAlertController(
            title: "切换音源",
            message: candidates.isEmpty
                ? "没有其他可用音源，请到「设置 → 音源管理」开启"
                : "当前：\(Theme.sourceName(current))\n会在所选音源里搜同名歌曲并接着播",
            preferredStyle: .actionSheet
        )

        for s in candidates {
            sheet.addAction(UIAlertAction(title: Theme.sourceName(s), style: .default) { [weak self] _ in
                self?.performSwitch(to: s)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        // iPad / 部分场景需要 popover 锚点，否则会崩
        sheet.popoverPresentationController?.sourceView = sourceLabel
        sheet.popoverPresentationController?.sourceRect = sourceLabel.bounds
        present(sheet, animated: true)
    }

    private func performSwitch(to source: String) {
        let name = Theme.sourceName(source)
        errorLabel.text = "正在切到 \(name)…"
        errorLabel.isHidden = false

        PlayerManager.shared.switchTo(source: source) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.errorLabel.isHidden = true
                self.setSourceLabel(source)
            } else {
                self.errorLabel.text = "⚠️ \(name) 里没找到这首歌"
                self.errorLabel.isHidden = false
            }
        }
    }

    // MARK: - 工具

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
