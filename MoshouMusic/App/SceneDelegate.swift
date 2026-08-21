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
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // 保存数据
        ConfigStore.shared.save()
    }
}
