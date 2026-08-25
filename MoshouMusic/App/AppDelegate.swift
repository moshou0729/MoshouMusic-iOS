import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 配置音频会话
        configureAudioSession()

        // 初始化核心引擎
        _ = ScriptEngine.shared
        _ = PlayerManager.shared
        _ = ConfigStore.shared

        // LX 兼容层（洛雪社区音源）预加载——延后到首帧之后，避免拖慢启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            LXCompatEngine.shared.ensureLoaded()
        }

        Logger.info("墨守music 启动成功")

        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowAirPlay]
            )
            try session.setActive(true)
            Logger.info("AudioSession 配置成功")
        } catch {
            Logger.error("AudioSession 配置失败: \(error)")
        }
    }

    // MARK: - Background Fetch

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.newData)
    }
}
