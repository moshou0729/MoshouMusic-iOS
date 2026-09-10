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

        // 🚨 v1.0.126 异常退出取证：上次会话若未走 willTerminate 正常收尾，
        // 说明进程曾被系统直接终止（jetsam/挂起回收 —— 这种死法无崩溃记录）
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "moshou_session_alive") {
            Logger.persist("⚠️ 检测到上次会话未正常收尾（无崩溃记录）→ 进程曾被系统强制终止")
        }
        defaults.set(true, forKey: "moshou_session_alive")

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

        // 缓存上限兜底：超过 1 GB 时按「最久未修改优先」自动清理到 800 MB。
        // 放后台线程 + 延后执行，避免启动阶段遍历目录拖慢首帧。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            ConfigStore.shared.enforceCacheLimit()
        }

        Logger.info("墨守music 启动成功")
        Logger.persist("进程启动（墨守music）")

        // 若上次发生过崩溃，弹窗展示原因，方便定位
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showCrashLogIfNeeded()
        }

        // 🚨 v1.0.128：扫描系统崩溃/内存回收报告（TrollStore no-sandbox 权限可读
        // /var/mobile/Library/Logs/CrashReporter）—— 熄屏被杀的最终取证：
        // JetsamEvent 报告会写明终止原因（内存高水位/vnodes/每进程上限等）
        scanSystemReports()

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

    /// v1.0.126：正常收尾标记 —— 与启动时的 alive 检查配对，
    /// 区分「用户主动杀掉」和「系统强制终止」
    func applicationWillTerminate(_ application: UIApplication) {
        UserDefaults.standard.set(false, forKey: "moshou_session_alive")
        Logger.persist("会话正常退出（applicationWillTerminate）")
    }

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
            // v1.0.118：'what'(0x77686174) 多为 mediaserverd 忙于恢复其它会话
            //（如已删除「音乐」App 的残留状态）—— 稍后重试一次；播放路径的
            // ensureAudioSessionActive 还会继续兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let s = AVAudioSession.sharedInstance()
                do {
                    if s.category != .playback {
                        try s.setCategory(.playback, mode: .default,
                                         options: [.allowBluetooth, .allowAirPlay])
                    }
                    try s.setActive(true)
                    Logger.info("AudioSession 二次配置成功")
                } catch {
                    Logger.error("AudioSession 二次配置仍失败: \(error)（播放时会再次兜底激活）")
                }
            }
        }
    }

    // MARK: - 🚨 v1.0.128 系统崩溃/内存回收报告扫描（no-sandbox 取证）

    private static let systemReportPath: String = {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("system_report.log")
    }()

    /// 扫描 CrashReporter 目录：找最近 7 天内提及墨守music 的系统报告
    ///（JetsamEvent-*.ips = 内存回收杀进程；MoshouMusic-*.ips = 崩溃），
    /// 提取终止原因摘要持久化 + 全文留档到 Documents 供诊断页展示
    private func scanSystemReports() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) {
            self.doScanSystemReports()
        }
    }

    private func doScanSystemReports() {
        let dir = "/var/mobile/Library/Logs/CrashReporter"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            Logger.persist("系统报告目录不可读 /var/mobile/Library/Logs/CrashReporter（no-sandbox 未生效？）")
            return
        }
        let entries = names
            .filter { $0.hasSuffix(".ips") }
            .compactMap { name -> (String, Date)? in
                let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name)
                guard let mtime = attrs?[.modificationDate] as? Date else { return nil }
                return (name, mtime)
            }
            .sorted { $0.1 > $1.1 }
        guard !entries.isEmpty else {
            Logger.persist("系统报告目录为空：\(dir)")
            return
        }
        for (name, mtime) in entries.prefix(40) {
            // 只关心最近 7 天
            guard mtime.timeIntervalSinceNow > -7 * 24 * 3600 else { break }
            guard let raw = fm.contents(atPath: dir + "/" + name) else { continue }
            let blob = String(data: raw.prefix(512 * 1024), encoding: .utf8) ?? ""
            guard blob.contains("MoshouMusic") else { continue }
            // 命中：提取终止原因相关行做摘要
            let keyLines = blob.split(separator: "\n").filter {
                $0.localizedCaseInsensitiveContains("MoshouMusic") ||
                $0.localizedCaseInsensitiveContains("exception") ||
                $0.localizedCaseInsensitiveContains("termination") ||
                $0.localizedCaseInsensitiveContains("per-process") ||
                $0.localizedCaseInsensitiveContains("reason") ||
                $0.localizedCaseInsensitiveContains("VM Stats") ||
                $0.localizedCaseInsensitiveContains("rpages") ||
                $0.localizedCaseInsensitiveContains("kill")
            }.prefix(30)
            let summary = "\(name)（\(mtime)）\n" + keyLines.joined(separator: "\n")
            Logger.persist("🚨 发现系统报告：\(name)（详情见诊断页底部）")
            try? summary.write(toFile: AppDelegate.systemReportPath, atomically: true, encoding: .utf8)
            return
        }
        Logger.persist("近 7 天系统报告中无与墨守music相关的条目（共扫描 \(min(entries.count, 40)) 份）")
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
        // v1.0.127：SIGTRAP = Swift 运行时陷阱（fatalError/越界/强解包 nil），
        // 此前未挂钩 → 这类崩溃不写 crash.log，会被误判为「被系统直接终止」
        signal(SIGTRAP, moshouSignalHandler)
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
