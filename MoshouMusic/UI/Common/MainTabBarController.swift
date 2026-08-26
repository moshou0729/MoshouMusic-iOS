import UIKit

/// 主标签栏 — Material Design 3 风格底部导航
/// 四个标签: 搜索 / 排行 / 我的 / 设置
class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabs()
        setupMiniPlayer()

        // 初始播放状态决定迷你播放条可见性与底部安全区预留
        let hasSong = PlayerManager.shared.currentSong != nil
        setMiniPlayerVisible(hasSong, animated: false)

        // 监听播放状态：有当前歌曲才显示播放条并预留安全区
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerStateChanged(_:)),
            name: .playerStateChanged, object: nil
        )
    }

    private func setupTabs() {
        let searchVC = SearchViewController()
        searchVC.tabBarItem = UITabBarItem(
            title: "搜索",
            image: UIImage(systemName: "magnifyingglass"),
            selectedImage: UIImage(systemName: "magnifyingglass.fill")
        )

        let rankingVC = RankingViewController()
        rankingVC.tabBarItem = UITabBarItem(
            title: "排行",
            image: UIImage(systemName: "chart.bar"),
            selectedImage: UIImage(systemName: "chart.bar.fill")
        )

        let playlistVC = PlaylistViewController()
        playlistVC.tabBarItem = UITabBarItem(
            title: "我的",
            image: UIImage(systemName: "music.note.house"),
            selectedImage: UIImage(systemName: "music.note.house.fill")
        )

        let settingsVC = SettingsViewController()
        settingsVC.tabBarItem = UITabBarItem(
            title: "设置",
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )

        // 每个标签包装导航控制器
        let controllers = [searchVC, rankingVC, playlistVC, settingsVC].map {
            UINavigationController(rootViewController: $0)
        }

        viewControllers = controllers

        // Material Design 3 风格
        tabBar.tintColor = Theme.primary
        tabBar.backgroundColor = Theme.cardBg
    }

    // MARK: - 迷你播放条

    private var miniPlayerBar: MiniPlayerBar?

    private func setupMiniPlayer() {
        let bar = MiniPlayerBar()
        view.addSubview(bar)

        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 64)
        ])

        miniPlayerBar = bar

        // 点击展开播放页
        bar.onTap = { [weak self] in
            self?.presentPlayer()
        }
    }

    /// 控制迷你播放条的显示/隐藏，以及对应的底部安全区预留
    /// - 有当前歌曲时：显示播放条 + 底部预留 64pt，各页面 safe area 自动上移避开
    /// - 无当前歌曲时：隐藏播放条 + 不预留，页面回归正常布局
    private func setMiniPlayerVisible(_ visible: Bool, animated: Bool) {
        guard let bar = miniPlayerBar else { return }

        let work = {
            // 同步调整安全区，避免页面内容被播放条遮挡
            self.additionalSafeAreaInsets.bottom = visible ? 64 : 0
            bar.alpha = visible ? 1.0 : 0.0
            self.view.layoutIfNeeded()
        }

        if visible {
            bar.isHidden = false
            if animated {
                UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut, animations: work)
            } else {
                work()
            }
        } else {
            if animated {
                UIView.animate(
                    withDuration: 0.25, delay: 0, options: .curveEaseInOut,
                    animations: work,
                    completion: { _ in bar.isHidden = true }
                )
            } else {
                work()
                bar.isHidden = true
            }
        }
    }

    @objc private func playerStateChanged(_ notification: Notification) {
        let hasSong = PlayerManager.shared.currentSong != nil
        setMiniPlayerVisible(hasSong, animated: true)
    }

    private func presentPlayer() {
        let playerVC = PlayerViewController()
        playerVC.modalPresentationStyle = .overFullScreen
        playerVC.modalTransitionStyle = .crossDissolve
        present(playerVC, animated: true)
    }
}