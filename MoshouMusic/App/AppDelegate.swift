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
            autoDegradeGuardTierIfNeeded()
            // v1.0.140：被杀续播 —— 用户重新打开 App 时自动接续上一首（快照进度）。
            // 延后 2.5s 等音频会话二次配置与 LX 音源脚本就绪。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PlayerManager.shared.autoResumeLastPlaybackAfterKill()
            }
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

    /// v1.0.160：熄屏自保档位的自动降档保护。
    ///
    /// 若上次进程死在「屏变重建之后、存活确认（12s 心跳）之前」，说明当前快速档
    ///（3s/6s 重建）在避杀上不够 —— 累计 2 次就自动降回保守档（12/20s），
    /// 免得用户每次锁屏都白搭一次「进程被杀 = 停播」。
    /// 用户可在悬浮设置页把开关重新打开（会清零计数）来再次尝试快速档。
    private func autoDegradeGuardTierIfNeeded() {
        let pending = ConfigStore.shared.floatingGuardRebuildTs
        guard pending > 0 else { return }
        ConfigStore.shared.floatingGuardRebuildTs = 0
        let strikes = ConfigStore.shared.floatingGuardKillStrikes + 1
        ConfigStore.shared.floatingGuardKillStrikes = strikes
        Logger.persist("防护降档计数：重建后未活到 12s 即被强杀（第 \(strikes) 次）")
        if strikes >= 2, ConfigStore.shared.isFloatingWakeParkEnabled {
            ConfigStore.shared.isFloatingWakeParkEnabled = false
            ConfigStore.shared.floatingGuardKillStrikes = 0
            Logger.persist("⚠️ 连续两次重建后被强杀 —— 自动降回保守档（屏变后 12s 重建）；如需重试请在悬浮设置页重新打开「锁屏显示悬浮窗」")
        }
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
        // v1.0.131：JetsamEvent 报告可能在子目录 → 顶层 + 一层子目录都扫
        var all: [(String, String, Date)] = []   // (相对路径, 全路径, mtime)
        var subdirCount = 0
        for n in names {
            let p = dir + "/" + n
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                subdirCount += 1
                if let sub = try? fm.contentsOfDirectory(atPath: p) {
                    for s in sub where s.hasSuffix(".ips") {
                        let sp = p + "/" + s
                        if let m = try? fm.attributesOfItem(atPath: sp)[.modificationDate] as? Date {
                            all.append((n + "/" + s, sp, m))
                        }
                    }
                }
            } else if n.hasSuffix(".ips") {
                if let m = try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date {
                    all.append((n, p, m))
                }
            }
        }
        let entries = all.sorted { $0.2 > $1.2 }
        guard !entries.isEmpty else {
            Logger.persist("系统报告目录为空：\(dir)（子目录 \(subdirCount) 个）")
            return
        }
        // v1.0.131 修两个匹配缺陷：①看门狗报告正文会 dump 全设备进程列表（含我们的
        // 名字），旧逻辑把别人的报告（如 B 站）误命中；②首个命中就 return，真正的
        // JetsamEvent 排不上队。新规则：头 2KB（report 自身 procname 所在）含墨守 =
        // 肯定是我们的；或文件名 JetsamEvent-* 且正文含墨守 = 候选。最多收集 3 份。
        var matched: [(String, String)] = []   // (名称, 摘要)
        for (rel, path, mtime) in entries where mtime.timeIntervalSinceNow > -7 * 24 * 3600 {
            guard matched.count < 3 else { break }
            guard let raw = fm.contents(atPath: path) else { continue }
            let blob = String(data: raw.prefix(512 * 1024), encoding: .utf8) ?? ""
            let header = String(data: raw.prefix(2048), encoding: .utf8) ?? ""
            let isOurs = header.contains("MoshouMusic")
            let isJetsamCandidate = !isOurs && rel.contains("JetsamEvent") && blob.contains("MoshouMusic")
            guard isOurs || isJetsamCandidate else { continue }
            // 摘要逐行截断 400 字符（.ips 正文常是一整行巨型 JSON）+ 单份 8KB 封顶
            let keyLines = blob.split(separator: "\n").filter {
                $0.localizedCaseInsensitiveContains("MoshouMusic") ||
                $0.localizedCaseInsensitiveContains("exception") ||
                $0.localizedCaseInsensitiveContains("termination") ||
                $0.localizedCaseInsensitiveContains("per-process") ||
                $0.localizedCaseInsensitiveContains("reason") ||
                $0.localizedCaseInsensitiveContains("rpages") ||
                $0.localizedCaseInsensitiveContains("kill") ||
                $0.localizedCaseInsensitiveContains("procname")
            }.prefix(30).map { line -> String in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.count > 400 ? String(l.prefix(400)) + "…(超长行截断)" : l
            }
            var summary = "\(rel)（\(mtime)）\n" + keyLines.joined(separator: "\n")
            if summary.count > 8 * 1024 {
                summary = String(summary.prefix(8 * 1024)) + "\n…(单份摘要封顶)"
            }
            matched.append((rel, summary))
        }
        if matched.isEmpty {
            let newest = entries.prefix(10).map { $0.0 }.joined(separator: ", ")
            Logger.persist("近 7 天系统报告中无墨守music相关条目（共扫描 \(entries.count) 份，子目录 \(subdirCount) 个）。最新文件：\(newest)")
            return
        }
        var combined = matched.map { $0.1 }.joined(separator: "\n\n----\n\n")
        if combined.count > 20 * 1024 { combined = String(combined.prefix(20 * 1024)) + "\n…(摘要超长截断)" }
        Logger.persist("🚨 发现 \(matched.count) 份墨守music相关系统报告：\(matched.map { $0.0 }.joined(separator: "、"))（详情见诊断页底部）")
        try? combined.write(toFile: AppDelegate.systemReportPath, atomically: true, encoding: .utf8)
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
