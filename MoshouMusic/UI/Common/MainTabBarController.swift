import UIKit

/// 主标签栏 — Material Design 3 风格底部导航
/// 四个标签: 搜索 / 排行 / 我的 / 设置
class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabs()
        setupMiniPlayer()

        // 初始播放状态决定迷你播放条可见性
        let hasSong = PlayerManager.shared.currentSong != nil
        setMiniPlayerVisible(hasSong, animated: false)

        // 监听播放状态：变化时显示/隐藏播放条
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

    /// 播放条占据的高度（含阴影/微间距），FAB 等浮层用此值计算上移量
    static let miniPlayerVisibleHeight: CGFloat = 64

    private var miniPlayerBar: MiniPlayerBar?

    private func setupMiniPlayer() {
        let bar = MiniPlayerBar()
        view.addSubview(bar)

        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.miniPlayerVisibleHeight)
        ])

        miniPlayerBar = bar

        // 点击展开播放页
        bar.onTap = { [weak self] in
            self?.presentPlayer()
        }
    }

    /// 控制迷你播放条的显示/隐藏，并通过通知告知各页面（如 FAB）单独让位
    /// - v1.0.20 起**不再**修改 `additionalSafeAreaInsets`（避免各页面整体上移留死区）
    /// - 改为广播通知，让像「我的」页右下 FAB 这类悬浮元素自行抬升
    private func setMiniPlayerVisible(_ visible: Bool, animated: Bool) {
        guard let bar = miniPlayerBar else { return }

        let work = {
            bar.alpha = visible ? 1.0 : 0.0
            self.view.layoutIfNeeded()
        }

        let finish: (Bool) -> Void = { _ in
            // 切换完成广播一次，让 FAB 等浮层单独上移
            NotificationCenter.default.post(
                name: .miniPlayerVisibilityChanged,
                object: nil,
                userInfo: ["visible": visible]
            )
        }

        if visible {
            bar.isHidden = false
            if animated {
                UIView.animate(
                    withDuration: 0.25, delay: 0, options: .curveEaseInOut,
                    animations: work, completion: finish
                )
            } else {
                work()
                finish(true)
            }
        } else {
            if animated {
                UIView.animate(
                    withDuration: 0.25, delay: 0, options: .curveEaseInOut,
                    animations: work,
                    completion: { _ in
                        bar.isHidden = true
                        finish(true)
                    }
                )
            } else {
                work()
                bar.isHidden = true
                finish(true)
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

// MARK: - 全局通知名（迷你播放条可见性变化，让各页面浮层单独让位）

extension Notification.Name {
    /// userInfo: ["visible": Bool]
    static let miniPlayerVisibilityChanged = Notification.Name("MainTabBarController.miniPlayerVisibilityChanged")
}
