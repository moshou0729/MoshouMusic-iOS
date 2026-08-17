import UIKit

/// 主标签栏 — Material Design 3 风格底部导航
/// 四个标签: 搜索 / 排行 / 我的 / 设置
class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabs()
        setupMiniPlayer()
    }

    private func setupTabs() {
        let searchVC = SearchViewController()
        searchVC.tabBarItem = UITabBarItem(
            title: "搜索",
            image: UIImage(systemName: "magnifyingcircle"),
            selectedImage: UIImage(systemName: "magnifyingcircle.fill")
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

    private func presentPlayer() {
        let playerVC = PlayerViewController()
        playerVC.modalPresentationStyle = .overFullScreen
        playerVC.modalTransitionStyle = .crossDissolve
        present(playerVC, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 确保 mini player 在 tabBar 上方
    }
}
