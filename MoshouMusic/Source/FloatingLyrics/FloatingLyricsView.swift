import UIKit

/// 悬浮歌词视图 — 显示当前歌词行 + 下一行预览
class FloatingLyricsView: UIView {

    private let currentLyricLabel = UILabel()
    private let nextLyricLabel = UILabel()
    private let lockIcon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // 当前行
        currentLyricLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        currentLyricLabel.textColor = .white
        currentLyricLabel.textAlignment = .center
        currentLyricLabel.numberOfLines = 1
        currentLyricLabel.text = "悬浮歌词"
        addSubview(currentLyricLabel)

        // 下一行 (预览)
        nextLyricLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        nextLyricLabel.textColor = .white.withAlphaComponent(0.5)
        nextLyricLabel.textAlignment = .center
        nextLyricLabel.numberOfLines = 1
        addSubview(nextLyricLabel)

        // 锁定图标
        lockIcon.image = UIImage(systemName: "lock.fill")?
            .withTintColor(.white.withAlphaComponent(0.6), renderingMode: .alwaysOriginal)
        lockIcon.contentMode = .scaleAspectFit
        lockIcon.isHidden = true
        addSubview(lockIcon)

        [currentLyricLabel, nextLyricLabel, lockIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            currentLyricLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            currentLyricLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            currentLyricLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            nextLyricLabel.topAnchor.constraint(equalTo: currentLyricLabel.bottomAnchor, constant: 2),
            nextLyricLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nextLyricLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            nextLyricLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            lockIcon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            lockIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            lockIcon.widthAnchor.constraint(equalToConstant: 14),
            lockIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func updateLyrics(text: String, translation: String? = nil) {
        UIView.transition(with: currentLyricLabel, duration: 0.3, options: .transitionCrossDissolve) {
            self.currentLyricLabel.text = text
        }

        if let translation = translation, !translation.isEmpty {
            nextLyricLabel.text = translation
        } else {
            nextLyricLabel.text = ""
        }
    }

    func updateLockState(_ locked: Bool) {
        lockIcon.isHidden = !locked
    }
}
