import UIKit

/// 主标签栏 — Material Design 3 风格底部导航
/// 四个标签: 搜索 / 排行 / 我的 / 设置
class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabs()
        setupMiniPlayer()

        // 初始播放状态决定迷你播放条可见性
        hasCurrentSong = PlayerManager.shared.currentSong != nil
        updatePlayerChrome(animated: false)

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

    /// 是否有当前歌曲（决定播放条/收起控件是否该出现）
    private var hasCurrentSong = false
    /// 是否已收起为角落小方块
    private var isCollapsed = false

    private var miniPlayerBar: MiniPlayerBar?
    private var collapsedControl: CollapsedPlayerControl?

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
        // 左滑收起为角落小方块
        bar.onSwipeLeft = { [weak self] in
            self?.setCollapsed(true, animated: true)
        }

        setupCollapsedControl()
    }

    private func setupCollapsedControl() {
        let c = CollapsedPlayerControl()
        c.isHidden = true
        c.alpha = 0
        view.addSubview(c)
        c.translatesAutoresizingMaskIntoConstraints = false
        // 定位约束交给控件自己管理（拖动 / 就近吸附时改写 constant）
        let leadC = c.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0)
        let bottomC = c.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        NSLayoutConstraint.activate([
            leadC,
            bottomC,
            c.widthAnchor.constraint(equalToConstant: 56),
            c.heightAnchor.constraint(equalToConstant: 56),
        ])
        c.positionLeading = leadC
        c.positionBottom = bottomC
        c.configureGestures()
        // 短滑展开（方向取决于吸附侧，见控件内逻辑）
        c.onExpand = { [weak self] in
            self?.setCollapsed(false, animated: true)
        }
        collapsedControl = c
    }

    /// 设置收起/展开态并刷新视图
    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        updatePlayerChrome(animated: animated)
    }

    /// 根据「是否有歌 + 是否收起」刷新两个控件的可见性，并广播给各页面浮层
    /// - 完整播放条可见: 有歌 且 未收起
    /// - 角落小方块可见: 有歌 且 已收起
    /// - v1.0.20+ 不再改 `additionalSafeAreaInsets`（避免各页面整体上移留死区）
    private func updatePlayerChrome(animated: Bool) {
        let showBar = hasCurrentSong && !isCollapsed
        let showCollapsed = hasCurrentSong && isCollapsed
        if showBar { showMiniBar(animated: animated) } else { hideMiniBar(animated: animated) }
        if showCollapsed { showCollapsedControl(animated: animated) } else { hideCollapsedControl(animated: animated) }

        // 广播给「我的」页 FAB 等悬浮元素：有歌时让位，无歌时归位
        NotificationCenter.default.post(
            name: .miniPlayerVisibilityChanged,
            object: nil,
            userInfo: ["visible": hasCurrentSong]
        )
    }

    // MARK: - 显示 / 隐藏动画（缩小 / 展开均有动态效果）

    private func showMiniBar(animated: Bool) {
        guard let bar = miniPlayerBar else { return }
        bar.isHidden = false
        if animated {
            bar.alpha = 0
            bar.transform = CGAffineTransform(translationX: 0, y: 18)
            UIView.animate(withDuration: 0.32, delay: 0,
                           usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
                bar.alpha = 1
                bar.transform = .identity
            }
        } else {
            bar.alpha = 1
            bar.transform = .identity
        }
    }

    private func hideMiniBar(animated: Bool) {
        guard let bar = miniPlayerBar else { return }
        if animated {
            UIView.animate(withDuration: 0.24, animations: {
                bar.alpha = 0
                bar.transform = CGAffineTransform(translationX: 0, y: 18)
            }, completion: { _ in
                bar.isHidden = true
                bar.transform = .identity
            })
        } else {
            bar.alpha = 0
            bar.isHidden = true
            bar.transform = .identity
        }
    }

    private func showCollapsedControl(animated: Bool) {
        guard let c = collapsedControl else { return }
        c.isHidden = false
        if animated {
            c.alpha = 0
            c.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
            UIView.animate(withDuration: 0.34, delay: 0,
                           usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8) {
                c.alpha = 1
                c.transform = .identity
            }
        } else {
            c.alpha = 1
            c.transform = .identity
        }
    }

    private func hideCollapsedControl(animated: Bool) {
        guard let c = collapsedControl else { return }
        if animated {
            UIView.animate(withDuration: 0.24, animations: {
                c.alpha = 0
                c.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
            }, completion: { _ in
                c.isHidden = true
                c.transform = .identity
            })
        } else {
            c.alpha = 0
            c.isHidden = true
            c.transform = .identity
        }
    }

    @objc private func playerStateChanged(_ notification: Notification) {
        let hasSong = PlayerManager.shared.currentSong != nil
        // 没歌了就重置收起态，下次播放从完整条开始
        if !hasSong { isCollapsed = false }
        hasCurrentSong = hasSong
        updatePlayerChrome(animated: true)
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
