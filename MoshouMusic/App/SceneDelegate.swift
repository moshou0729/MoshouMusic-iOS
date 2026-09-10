import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainTabBarController()
        window.makeKeyAndVisible()
        self.window = window

        // 应用主题（App 内深浅模式独立于系统设置，强制覆盖窗口外观，
        // 防止系统深色模式下系统控件变黑导致黑底黑字）
        Theme.applyAppearance()
        window.overrideUserInterfaceStyle = ConfigStore.shared.isDarkMode ? .dark : .light

        // 上次开启过悬浮歌词则自动恢复（此前重启后不会自动显示，容易被当成「悬浮坏了」）
        // v1.0.121：启动时 App 在前台 —— 悬浮窗隐藏，切到其他应用/桌面自动出现
        FloatingLyricsManager.shared.suppressWhileInApp()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 🚨 v1.0.116：参考网易云式占坑 —— 回前台立即抢占音频会话恢复被中断的播放
        PlayerManager.shared.recoverIfInterruptedOnForeground()
        // v1.0.121：App 内不显示悬浮 —— 销毁窗口，切出去时自动恢复
        FloatingLyricsManager.shared.suppressWhileInApp()
        Logger.persist("sceneDidBecomeActive 回前台")
    }

    /// v1.0.121：离开 App（切其他应用 / 回桌面）→ 悬浮窗自动出现
    func sceneWillResignActive(_ scene: UIScene) {
        Logger.persist("sceneWillResignActive 失去焦点")
        FloatingLyricsManager.shared.resumeWhenLeavingApp()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Logger.persist("sceneDidEnterBackground 进入后台")
        // 保存数据
        ConfigStore.shared.save()
        FloatingLyricsManager.shared.resumeWhenLeavingApp()
    }

    // MARK: - 文件导入（从 Files / 分享菜单「墨守music」打开 .lxmc / .json）

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        importLXFileFromURL(url)
    }

    private func importLXFileFromURL(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let secured = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if secured { url.stopAccessingSecurityScopedResource() }

            guard let fileData = data else {
                DispatchQueue.main.async {
                    self.presentAlert(title: "读取文件失败", message: url.lastPathComponent)
                }
                return
            }

            do {
                let lists = try LXPlaylistBridge.parseLXMC(data: fileData)
                let (pls, songs) = LXPlaylistBridge.importParsed(lists)
                DispatchQueue.main.async {
                    self.presentAlert(title: "导入成功",
                                      message: "共导入 \(pls) 个歌单，\(songs) 首歌曲")
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentAlert(title: "导入失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        guard let root = window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController {
            if let nav = presented as? UINavigationController, let vc = nav.topViewController {
                top = vc
            } else {
                top = presented
            }
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        top.present(alert, animated: true)
    }
}
