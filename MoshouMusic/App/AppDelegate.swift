import UIKit
import AVFoundation
import Darwin

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 崩溃采集：捕获未处理异常/信号，写入 Documents/crash.log，
        // 并在下次启动时弹窗让用户复制给开发者（避免洛雪脚本等异常直接闪退）
        installCrashReporter()

        // 配置音频会话
        configureAudioSession()

        // 初始化核心引擎
        _ = ScriptEngine.shared
        _ = PlayerManager.shared
        _ = ConfigStore.shared

        // LX 兼容层（洛雪社区音源）预加载——延后到首帧之后，避免拖慢启动
        // 用 defer 包一层，确保即使预加载抛出异常也不会拖垮整个 App
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            LXCompatEngine.shared.ensureLoaded()
        }

        Logger.info("墨守music 启动成功")

        // 若上次发生过崩溃，弹窗展示原因，方便定位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showCrashLogIfNeeded()
        }

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

    // MARK: - Crash Reporter

    private func crashLogPath() -> String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("crash.log")
    }

    private func appendCrash(_ msg: String) {
        let path = crashLogPath()
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(msg.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func installCrashReporter() {
        // 注意：NSSetUncaughtExceptionHandler 需要 @convention(c) 函数指针，
        // 不能是捕获了上下文的闭包，因此用顶层函数 moshouHandleException 承接。
        NSSetUncaughtExceptionHandler(moshouHandleException)

        signal(SIGABRT, moshouSignalHandler)
        signal(SIGSEGV, moshouSignalHandler)
        signal(SIGBUS, moshouSignalHandler)
        signal(SIGILL, moshouSignalHandler)
        signal(SIGFPE, moshouSignalHandler)
    }

    private func showCrashLogIfNeeded() {
        let path = crashLogPath()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty else { return }
        guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first?.rootViewController else { return }

        let alert = UIAlertController(
            title: "检测到上次崩溃",
            message: "请把下面信息复制发给开发者，以便定位问题：\n\n" + content,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "复制", style: .default) { _ in
            UIPasteboard.general.string = content
        })
        alert.addAction(UIAlertAction(title: "忽略", style: .cancel))
        root.present(alert, animated: true)

        // 展示后清空，避免每次启动都弹
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// 采集当前线程调用栈（用于崩溃日志）。在信号处理器中调用，
/// 仅使用 async-signal-safe 的 backtrace / backtrace_symbols。
func moshouBacktrace() -> String {
    var buffer = [UnsafeMutableRawPointer?](repeating: nil, count: 80)
    let count = backtrace(&buffer, Int32(buffer.count))
    guard count > 0 else { return "(无调用栈)" }
    var out = ""
    if let symbols = backtrace_symbols(&buffer, count) {
        for i in 0..<Int(count) {
            let sym: UnsafeMutablePointer<CChar>? = symbols[i]
            if let s = sym, let str = String(validatingUTF8: s) {
                out += "\(i)\t\(str)\n"
            } else {
                out += "\(i)\t<unknown>\n"
            }
        }
        free(symbols)
    } else {
        for i in 0..<Int(count) {
            if let p = buffer[i] {
                out += "\(i)\t\(p)\n"
            }
        }
    }
    return out
}

@_cdecl("moshouHandleException")
func moshouHandleException(_ exception: NSException) {
    let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()
    let path = (dir as NSString).appendingPathComponent("crash.log")
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let msg = """
    === UNCAUGHT EXCEPTION \(Date()) ===
    NAME: \(exception.name.rawValue)
    REASON: \(exception.reason ?? "unknown")
    STACK:
    \(stack)

    """
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(msg.data(using: .utf8) ?? Data())
        fh.closeFile()
    } else {
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }
    Logger.error("捕获未处理异常: \(exception.name.rawValue) - \(exception.reason ?? "")")
}

@_cdecl("moshouSignalHandler")
func moshouSignalHandler(sig: Int32) {
    let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()
    let full = (path as NSString).appendingPathComponent("crash.log")
    let bt = moshouBacktrace()
    let msg = "\n=== SIGNAL \(sig) \(Date()) ===\nBACKTRACE:\n\(bt)\n"
    if let fh = FileHandle(forWritingAtPath: full) {
        fh.seekToEndOfFile()
        fh.write(msg.data(using: .utf8) ?? Data())
        fh.closeFile()
    } else {
        try? msg.write(toFile: full, atomically: true, encoding: .utf8)
    }
    // 还原默认处理并重新触发，保留系统崩溃报告
    signal(sig, SIG_DFL)
    raise(sig)
}
