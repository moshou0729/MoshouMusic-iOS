import AVFoundation
import MediaPlayer
import UIKit
import Foundation

// MARK: - 试用/赞助版音源拦截
/// 某些用户导入的洛雪社区脚本（如 ikun 音源）在试用到期后会返回一个「真实可播放」的
/// TTS 音频链接（内容是一段“请在 xxx 购买卡密”的语音播报）。AVPlayer 会把它当正版
/// 歌曲播出来，于是每首歌都变成那段购买提示。
/// 这里在「拿到链接、尚未播放」前做一次拦截：命中则**不播放该链接**，改走自动换源
/// （kg/tx/wy/mg），既不播那段提示音，也能用正常音源把歌放出来。
struct SourceGuard {
    /// 音源 id（小写）命中其一即视为试用/赞助版，禁止直接播放
    static let blockedSourceSubstrings = ["ikun", "shopicanshare", "卡密", "赞助版", "trial"]
    /// 返回的播放链接（小写）命中其一即视为伪造链接（试用提示托管地址等）
    static let forgedUrlTokens = ["shopicanshare", "ikun", "卡密", "购买卡密", "赞助版", "试用", "trial"]

    static func isBlockedSource(_ id: String) -> Bool {
        let s = id.lowercased()
        return blockedSourceSubstrings.contains { s.contains($0) }
    }

    static func isForgedUrl(_ url: String) -> Bool {
        let s = url.lowercased()
        return forgedUrlTokens.contains { s.contains($0) }
    }

    /// v1.0.86：脚本内容级黑名单 —— 用户导入的试用脚本可能改名（id 不含 ikun），
    /// 但其 TTS 提示文案/托管地址必然出现在脚本源码里，按内容拦截。
    static let blockedContentTokens = ["shopicanshare", "购买卡密", "卡密后", "赞助版ikun", "以继续试用", "试用版音源"]

    static func isBlockedScriptContent(_ code: String) -> Bool {
        let s = code.lowercased()
        return blockedContentTokens.contains { s.contains($0.lowercased()) }
    }
}

/// 播放管理器 — 单例，管理音频播放、队列、锁屏控制、歌词同步
class PlayerManager: NSObject {

    static let shared = PlayerManager()

    // MARK: - 状态 (用于 UI 绑定)

    var onStateChanged: ((PlayerState) -> Void)?
    var onTimeChanged: ((Double, Double) -> Void)? // (currentTime, duration)
    var onLyricsChanged: ((Int, [LRCLine]) -> Void)? // (currentIndex, allLines)
    var onSongChanged: ((Song?) -> Void)?

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentSong: Song?
    private(set) var currentSource: String = "kg"
    private(set) var currentLyrics: [LRCLine] = []
    private(set) var currentLyricIndex: Int = -1
    /// 当前封面（供播放页/迷你条在出场后补显，避免错过 artworkLoaded 通知）
    private(set) var currentArtwork: UIImage?

    /// 最近一次播放失败的原因（供播放页展示，便于排查是哪个源/哪一步失败）
    private(set) var lastPlayError: String?

    private(set) var playMode: PlayMode {
        get { PlayMode(rawValue: ConfigStore.shared.playMode) ?? .listRepeat }
        set { ConfigStore.shared.playMode = newValue.rawValue }
    }

    // MARK: - 私有

    private var player: AVPlayer!
    private var timeObserverToken: Any?
    /// v1.0.78：当前音源是否被标记为已知试用/赞助版，用于 readyToPlay 阶段的极短音频兜底拦截
    private var suspectCurrentSource = false
    /// KVO 不再使用 context 指针：旧实现用 static let 指针做上下文比较，
    /// 在 observeValue 内读取它会触发 Swift 独占访问运行时（swift_endAccess → abort）崩溃。
    /// 改为 addObserver 传 context: nil，observeValue 内仅按「object 身份 + keyPath」判定，
    /// 并把处理统一派发到主线程，避免后台线程 KVO 与切歌时的 observedItem 写操作竞争。
    /// 当前正在观察的播放项，切歌前必须先移除其 KVO 观察者，否则旧项释放时会闪退
    private var observedItem: AVPlayerItem?

    private var playQueue: [Song] = []
    private var queueIndex: Int = 0

    private var sourceSwitcher: SourceSwitcher!
    private var isSwitchingSource = false

    /// v1.0.88 切歌取消令牌：每次 play()/switchTo() 自增。取链链路（内置源 → LX 兜底 →
    /// 自动换源）可能耗时数十秒，旧链路的 completion 若不作废，会在用户已经切到新歌后
    /// 才返回并顶掉新歌（播错歌 / 状态错乱）。所有异步回调先比对令牌再继续。
    private var playGeneration = 0

    /// v1.0.95 播放提交标记：本代取链一旦真正开播（commitStartPlayback），
    /// 同代的其余竞速结果（直接取链 / 提前跨源兜底）一律作废，防止重复开播或顶歌。
    private var playbackCommitted = false

    // MARK: - Init

    override init() {
        super.init()
        setupPlayer()
        setupRemoteCommand()
        startPlaybackEndFuse()
        sourceSwitcher = SourceSwitcher()
    }

    // MARK: - 播放器初始化

    private func setupPlayer() {
        player = AVPlayer()
        player.actionAtItemEnd = .none

        // 时间监听
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.handleTimeUpdate(time)
        }

        // 播放结束
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )

        // v1.0.110：系统中断 / 音频路由变化后自动续播。
        // 背景：用户删除了自带「音乐」App 后，iOS mediaserverd 在媒体会话恢复 /
        // 路由切换时仍会尝试唤起「音乐」的上次播放（弹「恢复音乐？」），并顺带
        // 中断第三方播放。系统只负责打断、不负责恢复 —— 这里补上恢复逻辑。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // v1.0.112：mediaserverd 被系统重启（「恢复音乐」弹窗场景高发）后，
        // 音频会话被强制反激活、AVPlayer 管线失效 → 「进 App 也播不了」。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        // v1.0.121：亮屏 Darwin 通知 —— 亮屏瞬间 mediaserverd 的媒体仲裁中断随之而来
        registerDisplayStatusObserver()
        // v1.0.122：后台歌词驱动 —— AVPlayer 周期时间观察者进后台经常停摆（与渲染
        // 同步挂钩），悬浮歌词随之停在占位不翻句。补一个挂在主 runloop common 模式
        // 的 0.5s Timer 兜底驱动（后台音频活跃时主 runloop 持续运行，Timer 不熄火）。
        startLyricDriveTimer()
    }

    /// v1.0.122：后台歌词驱动 Timer（0.5s，主 runloop common 模式，后台不熄火）
    private var lyricDriveTimer: Timer?

    private func startLyricDriveTimer() {
        guard lyricDriveTimer == nil else { return }
        Logger.info("后台歌词驱动 Timer 已启动(0.5s 主runloop兜底)")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateLyrics()
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricDriveTimer = timer
    }

    /// 中断前是否在播（来电 / 系统弹窗打断 → 结束后按此恢复）
    /// 🚨 v1.0.112：只在「确实在播时被打断」置 true，且**收到 .ended 不清、验证真正续播成功才清**——
    /// 「恢复音乐？」弹窗型中断的 .ended 经常不送达，过早清标记会让恢复链路彻底断掉。
    private var wasPlayingBeforeInterruption = false
    /// 中断看门狗（.ended 通知被系统吞掉时接管恢复）
    private var interruptionWatchdog: DispatchWorkItem?
    /// 上次「整链重建重播」兜底的时间（10s 内只兜底一次，防失败循环）
    private var lastRebuildReplayAt = Date.distantPast

    /// 系统中断处理：中断结束后自动续播（系统只打断不恢复，播放器需自行接管）
    @objc private func handleAudioSessionInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        DispatchQueue.main.async {
            switch type {
            case .began:
                if self.isPlaying {
                    self.wasPlayingBeforeInterruption = true
                    Logger.warn("音频会话被系统中断，暂停播放（中断结束后自动续播）")
                    self.pause()
                }
                // 🚨 v1.0.115：中断后进程失去后台音频保活资格会被挂起，先申请后台任务
                self.recoveryKeepAliveRenewed = false
                self.beginRecoveryKeepAlive()
                // 🚨 v1.0.112：「恢复音乐？」弹窗在亮屏瞬间弹出 → 中断 .began；
                // 但 .ended 在弹窗被丢弃/吞掉时永远不来 → 音乐永远停着。
                // 看门狗：3s 后开始接管恢复（若仍在 .interrupted 会自动避让，不与来电抢）。
                self.scheduleInterruptionWatchdog()
            case .ended:
                // v1.0.123 诊断：确认 .ended 是否送达（弹窗型中断常被吞，靠看门狗接管）
                Logger.info("音频会话中断结束通知(.ended)已送达，0.2s 后抢回")
                // v1.0.121：统一 0.2s 立即抢回（shouldResume 与否都先试，恢复入口自带守卫）
                let delay: TimeInterval = 0.2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.wasPlayingBeforeInterruption, !self.isPlaying else { return }
                    self.recoverAfterInterruption(reason: "中断结束通知")
                }
            @unknown default:
                break
            }
        }
    }

    /// 中断后统一恢复入口：先重新激活会话（被系统中断后 session 处于反激活状态，
    /// 不激活就 play() 会静默无声 —— 「进 App 点播放也没反应」的真凶），再续播
    private func recoverAfterInterruption(reason: String) {
        guard wasPlayingBeforeInterruption, !isPlaying else { return }
        Logger.info("中断恢复（\(reason)）：重新激活音频会话后续播")
        if ensureAudioSessionActive() {
            resume()
        } else {
            // 激活失败（mediaserverd 可能卡在找已删除的「音乐」App）：稍后重试，
            // 期间由后台任务保活防止进程被挂起、看门狗停摆
            scheduleActivationRetry(attemptsLeft: 5)
        }
    }
    /// 🚨 v1.0.116：参考主流音乐 App（网易云等）的「占坑」策略 —— 回前台立即
    /// 抢占会话恢复播放。「恢复音乐？」弹窗关闭后系统不会通知我们，但用户解锁
    /// 回到 App 这个动作本身就是可靠的恢复时机，主动接管，不再只依赖看门狗。
    func recoverIfInterruptedOnForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.wasPlayingBeforeInterruption, !self.isPlaying else { return }
            Logger.info("回前台：接管被中断的播放（网易云式占坑）")
            self.recoverAfterInterruption(reason: "回前台接管")
        }
    }

    private var activationRetryWork: DispatchWorkItem?

    /// 激活失败重试：先 deactivate 回收再 activate（对卡死的会话偶有奇效）
    private func scheduleActivationRetry(attemptsLeft: Int) {
        activationRetryWork?.cancel()
        guard attemptsLeft > 0 else {
            Logger.error("音频会话激活重试全部失败（mediaserverd 疑似卡死）")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.wasPlayingBeforeInterruption, !self.isPlaying else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            if self.ensureAudioSessionActive() {
                Logger.info("音频会话激活重试成功，续播")
                self.resume()
            } else {
                self.scheduleActivationRetry(attemptsLeft: attemptsLeft - 1)
            }
        }
        activationRetryWork = work
        // v1.0.123：重试间隔 1.5s→1.0s（mediaserverd 忙是秒级抖动，没必要等 1.5s）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 🚨 v1.0.115：中断期间进程失去「后台音频」保活资格（没在出声），几秒内会被
    /// iOS 挂起 —— 看门狗/重试全停摆，这就是「关掉弹窗后几秒内不续播」的原因。
    /// 中断开始即申请 ~30s 后台任务，撑完整个看门狗周期。
    private func beginRecoveryKeepAlive() {
        endRecoveryKeepAlive()
        recoveryBgTask = UIApplication.shared.beginBackgroundTask(withName: "interruption-recovery") { [weak self] in
            guard let self = self, self.wasPlayingBeforeInterruption, !self.isPlaying else {
                self?.endRecoveryKeepAlive()
                return
            }
            // v1.0.121：到期仍处中断未恢复 → 续期一次（总恢复窗口 ~60s），
            // 覆盖「亮屏后长时间停在锁屏 / 其他应用」的场景
            if self.recoveryKeepAliveRenewed {
                Logger.warn("恢复保活二次到期仍中断未恢复，停止续期")
                self.endRecoveryKeepAlive()
                return
            }
            self.recoveryKeepAliveRenewed = true
            Logger.info("恢复保活到期仍中断未恢复，续期后台任务")
            self.beginRecoveryKeepAlive()
        }
    }

    private func endRecoveryKeepAlive() {
        guard recoveryBgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(recoveryBgTask)
        recoveryBgTask = .invalid
    }

    private var recoveryBgTask: UIBackgroundTaskIdentifier = .invalid
    /// 恢复保活是否已续期过一次（防无限续期）
    private var recoveryKeepAliveRenewed = false

    // MARK: - 亮屏侦测（v1.0.121）

    private var displayStatusRegistered = false

    /// 监听 Darwin 通知 com.apple.iokit.hid.displayStatus（亮屏/灭屏，后台也送达）
    private func registerDisplayStatusObserver() {
        guard !displayStatusRegistered else { return }
        displayStatusRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    PlayerManager.shared.handleScreenWoke()
                }
            },
            "com.apple.iokit.hid.displayStatus" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 亮屏回调：mediaserverd 仲裁中断往往紧随其后 —— 备好保活并缩短看门狗首检
    func handleScreenWoke() {
        beginRecoveryKeepAlive()
        if wasPlayingBeforeInterruption && !isPlaying {
            Logger.info("亮屏：检测到中断未恢复，立即进入恢复节奏")
            attemptInterruptionRecovery(retriesLeft: 8)
        } else if isPlaying {
            // v1.0.123：亮屏瞬间先抢重激活会话（赶在 mediaserverd 媒体仲裁前占住，
            // 激活态下重激活无害；若仲裁仍反激活会话，随后 .began 走正常恢复链）
            if !ensureAudioSessionActive() {
                Logger.warn("亮屏抢占激活失败，交由中断恢复链接管")
            }
            scheduleInterruptionWatchdog(firstDelay: 1.2)
        } else {
            // 中断通常在亮屏后几百毫秒才到：看门狗首检提前到 1.2s
            scheduleInterruptionWatchdog(firstDelay: 1.2)
        }
    }

    /// 确保音频会话处于激活状态（幂等，激活状态下调用无害）
    @discardableResult
    private func ensureAudioSessionActive() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default,
                                        options: [.allowBluetooth, .allowAirPlay])
            }
            try session.setActive(true)
            return true
        } catch {
            // 不再吞错误：mediaserverd 卡死 / 会话冲突时这里会抛，留下日志方便定位
            Logger.error("音频会话激活失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 看门狗：中断 .began 后周期性检查。若播放器已脱离 .interrupted 但仍暂停
    /// （说明 .ended 通知被吞），主动接管恢复；仍在 .interrupted（来电/弹窗未关）
    /// 则避让并稍后重试。🚨 v1.0.122/123 提速：首检 3s→1.2s、重试 4s→2s、轮数 6→10
    /// （约 1.2s + 10×2s ≈ 21s，仍在 ~60s 恢复保活窗口内）——目标：熄屏点亮
    /// 1~2s 内续播；旧节奏（3s 首检 + 4s 重试）最快也要 3s+ 才恢复。
    private func scheduleInterruptionWatchdog(firstDelay: Double = 1.2) {
        interruptionWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.attemptInterruptionRecovery(retriesLeft: 10)
        }
        interruptionWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay, execute: work)
    }

    private func attemptInterruptionRecovery(retriesLeft: Int) {
        guard retriesLeft > 0 else {
            endRecoveryKeepAlive()
            return
        }
        guard wasPlayingBeforeInterruption, !isPlaying else { return }
        // 已脱离中断但没人在播（timeControlStatus=.paused）→ .ended 被吞，主动接管；
        // 正在播/缓冲中则不处理。来电期间恢复尝试会静默失败（setActive 报错被吞），
        // 状态如实回滚，不会真正干扰通话。
        if player.timeControlStatus == .paused {
            Logger.warn("中断后播放未恢复（.ended 未送达），看门狗自动接管")
            recoverAfterInterruption(reason: "看门狗接管")
        }
        if !isPlaying, retriesLeft > 1 {
            let next = DispatchWorkItem { [weak self] in
                self?.attemptInterruptionRecovery(retriesLeft: retriesLeft - 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: next)
        }
    }

    /// mediaserverd 重启（系统级媒体服务崩溃/复位）：会话反激活、播放器失效。
    /// 重建会话；若此前在播，自动重播当前歌（走完整取链链路）。
    @objc private func handleMediaServicesReset() {
        DispatchQueue.main.async {
            Logger.warn("mediaserverd 已重启，重建音频会话")
            self.endRecoveryKeepAlive()
            self.activationRetryWork?.cancel()
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default,
                                     options: [.allowBluetooth, .allowAirPlay])
            try? session.setActive(true)
            let shouldReplay = self.wasPlayingBeforeInterruption || self.isPlaying
            self.wasPlayingBeforeInterruption = false
            self.interruptionWatchdog?.cancel()
            guard shouldReplay, let song = self.currentSong else { return }
            self.isPlaying = false
            self.play(song: song, queue: self.playQueue)
        }
    }

    /// 音频路由变化：连上新输出设备（蓝牙耳机/车机）且此前在播 → 续播；
    /// 拔出耳机保持系统默认暂停（防外放尴尬），但记住播放意图
    @objc private func handleAudioRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        DispatchQueue.main.async {
            switch reason {
            case .newDeviceAvailable:
                guard self.wasPlayingBeforeInterruption || self.isPlaying else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self = self, !self.isPlaying else { return }
                    self.recoverAfterInterruption(reason: "音频路由切换")
                }
            case .oldDeviceUnavailable:
                if self.isPlaying {
                    self.wasPlayingBeforeInterruption = true
                }
            default:
                break
            }
        }
    }

    // MARK: - 播放控制

    /// 播放一首歌
    func play(song: Song, queue: [Song]? = nil) {
        // v1.0.88：作废上一条还在路上的取链链路（其 completion 会因令牌不符被丢弃）
        playGeneration += 1
        playbackCommitted = false
        // v1.0.112：主动切歌 = 用户明确意图，清中断恢复标记
        wasPlayingBeforeInterruption = false
        interruptionWatchdog?.cancel()
        activationRetryWork?.cancel()
        endRecoveryKeepAlive()
        if let queue = queue, !queue.isEmpty {
            playQueue = queue
            queueIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        }

        postQueueChanged()
        currentSong = song
        currentSource = song.source
        isSwitchingSource = false

        // v1.0.88：立刻停掉旧歌。旧实现要等新歌取链链路（可能几十秒）走完才
        // replaceCurrentItem，期间上一首一直在响，体感就是「切歌慢半拍」。
        // 现在切歌瞬间静音，新歌就绪后无缝接上。
        player.pause()
        isPlaying = false
        currentTime = 0
        // v1.0.94：同步清零进度回调——否则新歌取链期间，播放页左侧时间还挂着
        // 上一首停下来的 currentTime，右侧却是新歌的 "--:--"，观感割裂
        onTimeChanged?(0, 0)

        onSongChanged?(song)
        notifyStateChanged()

        // v1.0.71：把当前播放写入「最近播放」歌单。play(song:) 是所有播放入口
        // 的汇聚点（手动播 / next / previous / 列表播完自动 next / playAll），
        // 在这里记一次就全覆盖。PlaylistStore.recordPlayed 内部做去重 + 上限裁剪。
        PlaylistStore.shared.recordPlayed(song)

        loadAndPlay { [weak self] success in
            guard let self = self else { return }
            if !success {
                // 明确反馈播放失败，而不是静默吞掉
                Logger.error("播放失败，源=\(self.currentSource)")
                self.notifyStateChanged()
            }
        }
    }

    /// 恢复播放
    func resume() {
        // v1.0.88：没有可恢复的播放项（刚切歌还在取链 / 上一首已因失败被摘除）时，
        // 不要把可能残留的旧音频放出来
        guard observedItem != nil else { return }
        // 🚨 v1.0.112：系统中断（尤其「恢复音乐？」弹窗型）后 session 处于反激活状态，
        // 且 .ended 可能不送达；不重新激活就 play() 会静默无声 —— 用户「点播放没反应」的真凶。
        ensureAudioSessionActive()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        notifyStateChanged()
        verifyResumeStarted()
    }

    /// v1.0.112：0.8s 后核对播放是否真正起来了（不信任 isPlaying 标记，以
    /// AVPlayer.timeControlStatus 为准）。没起来 → 回滚状态 + 重新激活再试一次。
    private var resumeVerifyWorkItem: DispatchWorkItem?

    private func verifyResumeStarted() {
        resumeVerifyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying else { return }
            if self.player.timeControlStatus == .paused {
                Logger.warn("恢复播放未真正生效(timeControlStatus=.paused)，重新激活会话后重试")
                self.ensureAudioSessionActive()
                self.player.play()
                // 再给一次机会，若仍 paused 则如实回滚状态（UI 显示停止，看门狗可再接管）
                let retry = DispatchWorkItem { [weak self] in
                    guard let self = self, self.isPlaying else { return }
                    if self.player.timeControlStatus == .paused {
                        self.isPlaying = false
                        self.notifyStateChanged()
                        // 🚨 v1.0.115：续播两次都没起来 → 会话/播放器管线疑似卡死，
                        // 整链重建（重新取链 + 新 AVPlayerItem）做最终兜底。
                        // 10s 内只兜底一次，防失败循环。
                        if let song = self.currentSong,
                           Date().timeIntervalSince(self.lastRebuildReplayAt) > 10 {
                            self.lastRebuildReplayAt = Date()
                            Logger.warn("续播多次未生效，整链重建重播当前歌：\(song.name)")
                            self.play(song: song, queue: self.playQueue)
                        }
                    } else {
                        self.wasPlayingBeforeInterruption = false
                        self.interruptionWatchdog?.cancel()
                        self.endRecoveryKeepAlive()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: retry)
            } else {
                // 真正在播（或缓冲中）：中断恢复闭环完成
                self.wasPlayingBeforeInterruption = false
                self.interruptionWatchdog?.cancel()
                self.endRecoveryKeepAlive()
            }
        }
        resumeVerifyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 暂停
    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
        notifyStateChanged()
    }

    /// 切换播放/暂停
    func togglePlayPause() {
        // 用户手动操作 = 明确意图，清掉中断恢复标记（防看门狗违背用户意图反复拉起）
        wasPlayingBeforeInterruption = false
        interruptionWatchdog?.cancel()
        activationRetryWork?.cancel()
        endRecoveryKeepAlive()
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// 下一首
    func next() {
        guard !playQueue.isEmpty else { return }

        // queueIndex 可能因队列被替换而越界，先夹紧
        if queueIndex < 0 || queueIndex >= playQueue.count { queueIndex = 0 }

        switch playMode {
        case .random:
            queueIndex = Int.random(in: 0..<playQueue.count)
        default:
            queueIndex = (queueIndex + 1) % playQueue.count
        }

        play(song: playQueue[queueIndex])
    }

    /// 上一首
    func previous() {
        guard !playQueue.isEmpty else { return }

        // 如果播放超过3秒，回到开头
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        if queueIndex < 0 || queueIndex >= playQueue.count { queueIndex = 0 }
        queueIndex = (queueIndex - 1 + playQueue.count) % playQueue.count
        play(song: playQueue[queueIndex])
    }

    // MARK: - 手动切换音源

    /// 手动把当前这首歌换到指定音源播放
    /// 逻辑：在目标音源里按「歌名 + 歌手」搜索并匹配，再取播放链接
    /// - Parameter completion: 是否成功（失败时 lastPlayError 有原因）
    func switchTo(source target: String, completion: @escaping (Bool) -> Void) {
        guard let song = currentSong else {
            completion(false)
            return
        }

        guard ScriptEngine.shared.hasHandler(for: target) else {
            lastPlayError = "\(ConfigStore.shared.displayName(for: target)) 脚本未加载"
            notifyStateChanged()
            completion(false)
            return
        }

        let targetName = ConfigStore.shared.displayName(for: target)
        Logger.info("手动切换音源 → \(targetName)")

        lastPlayError = "正在切换到 \(targetName)…"
        notifyStateChanged()

        // v1.0.88：手动换源同样作废旧的取链链路，并立刻停掉旧歌（与切歌一致，
        // 避免「点了换源，旧歌还响半天」的迟滞感）
        playGeneration += 1
        let generation = playGeneration
        playbackCommitted = false
        player.pause()
        isPlaying = false
        currentTime = 0
        // v1.0.94：换源同样清零进度回调（与切歌一致）
        onTimeChanged?(0, 0)

        // 借用 SourceSwitcher 的搜索+匹配+取链接流程，但只限定目标这一个源
        sourceSwitcher.findPlayable(
            name: song.name,
            singer: song.singer,
            excluding: Set(ConfigStore.shared.selectableSourceIds.filter { $0 != target }),
            quality: ConfigStore.shared.defaultQuality,
            interval: song.interval
        ) { [weak self] hit in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 用户在切换期间又点了别的歌 → 本次结果作废
                guard generation == self.playGeneration else { return }
                guard let hit = hit, let url = URL(string: hit.url) else {
                    self.lastPlayError = "\(targetName) 没有找到这首歌"
                    self.notifyStateChanged()
                    completion(false)
                    return
                }

                self.currentSource = hit.source
                self.currentSong = hit.song
                self.lastPlayError = nil
                self.duration = 0
                self.currentTime = 0
                self.onSongChanged?(hit.song)
                self.onTimeChanged?(0, 0)
                self.currentLyrics = []
                self.currentLyricIndex = -1
                self.onLyricsChanged?(-1, [])

                self.startPlayback(url: url, song: hit.song)
                completion(true)
            }
        }
    }

    /// 跳转
    ///
    /// 必须过滤 NaN / 无穷 —— 流媒体（chunked / indefinite duration）下
    /// `item.duration.seconds` 会是 NaN，若直接构造 CMTime 交给 AVPlayer.seek 会立即崩溃。
    /// 这是「排行榜点播放闪退」的直接原因之一。
    func seek(to time: Double) {
        let target = PlayerManager.sane(time)
        // 已知总时长时不允许越界
        let clamped = duration > 0 ? min(target, duration) : target
        let cmTime = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        guard cmTime.isValid, !cmTime.isIndefinite else {
            Logger.warn("忽略无效的 seek 目标: \(time)")
            return
        }
        player.seek(to: cmTime) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
    }

    /// 把 NaN / ±Infinity / 负数统一压成 0，杜绝把脏值传给 AVPlayer 或锁屏信息中心
    static func sane(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }

    /// 切换播放模式
    func togglePlayMode() {
        let allCases = PlayMode.allCases
        let currentIndex = allCases.firstIndex(of: playMode) ?? 0
        let nextIndex = (currentIndex + 1) % allCases.count
        playMode = allCases[nextIndex]
        notifyStateChanged()
    }

    // MARK: - 加载并播放

    /// 移除某播放项的 KVO 观察者（防止其释放后仍被观察而闪退）
    private func removeObservers(from item: AVPlayerItem) {
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), context: nil)
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.duration), context: nil)
    }

    private func loadAndPlay(completion: @escaping (Bool) -> Void) {
        guard let song = currentSong else {
            completion(false)
            return
        }

        // v1.0.88：本条取链链路的令牌。期间用户再切歌（令牌自增）则本链路全部作废。
        let generation = playGeneration

        // v1.0.78：标记当前音源是否为已知试用/赞助版（用于 readyToPlay 阶段兜底拦截）
        suspectCurrentSource = SourceGuard.isBlockedSource(currentSource) || SourceGuard.isBlockedSource(song.source)

        // 记录上一次播放错误，供播放页展示
        lastPlayError = nil

        // 切歌时必须把时间轴归零：残留的旧时长（或上一首的 NaN）
        // 会被 updateNowPlayingInfo / 进度条读到并引发崩溃
        duration = 0
        currentTime = 0
        onTimeChanged?(0, 0)

        // 清理旧歌词
        currentLyrics = []
        currentLyricIndex = -1
        onLyricsChanged?(-1, [])

        notifyStateChanged()

        // v1.0.90：内置源与 LX 兼容层「并行竞速」——旧版串行（内置源超时 10s 挂掉后
        // 才轮到洛雪脚本），同步歌的内置官方源经常失效，每次都白等十几秒。
        // 现在两路同时发出，先拿到有效链接的立即开播，另一路结果作废；
        // 两路都失败才进入自动换源链路。
        let race = DualRace()
        let quality = ConfigStore.shared.defaultQuality
        let extra = song.meta ?? [:]

        let failToSwitch: (String) -> Void = { [weak self] reason in
            self?.handlePlayFailure(song: song, reason: reason, generation: generation, completion: completion)
        }

        // ① 内置源（ScriptEngine，官方平台脚本）
        ScriptEngine.shared.getMusicUrl(
            source: currentSource,
            songId: song.songmid,
            quality: quality,
            extra: extra
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // v1.0.88：切歌后旧链路结果一律作废
                guard generation == self.playGeneration else {
                    Logger.info("LX PlayerManager: 旧取链链路已作废（用户已切歌）")
                    return
                }
                if case .success(let url) = result,
                   !SourceGuard.isBlockedSource(self.currentSource),
                   !SourceGuard.isBlockedSource(song.source),
                   !SourceGuard.isForgedUrl(url),
                   let playUrl = URL(string: url) {
                    if race.settle(success: true) {
                        Logger.info("LX PlayerManager: 内置源竞速胜出 \(self.currentSource)")
                        self.startPlayback(url: playUrl, song: song)
                        completion(true)
                    }
                } else {
                    if case .failure(let error) = result {
                        Logger.error("获取播放链接失败[\(self.currentSource)]: \(error.localizedDescription)")
                    }
                    if race.settle(success: false) {
                        failToSwitch("该音源无法获取播放链接")
                    }
                }
            }
        }

        // ② LX 兼容层（洛雪社区脚本，首选脚本 dujia 已置顶且最先发出）
        if LXCompatEngine.shared.isPlatformAvailable(song.source) {
            LXCompatEngine.shared.getMusicUrl(
                platform: song.source,
                songId: song.songmid,
                quality: quality,
                extra: extra
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard generation == self.playGeneration else { return }
                    if case .success(let url) = result,
                       !SourceGuard.isBlockedSource(song.source),
                       !SourceGuard.isForgedUrl(url),
                       let playUrl = URL(string: url) {
                        if race.settle(success: true) {
                            Logger.info("LX PlayerManager: LX竞速胜出 \(song.source)")
                            self.startPlayback(url: playUrl, song: song)
                            completion(true)
                        }
                    } else {
                        if race.settle(success: false) {
                            failToSwitch("该音源无法获取播放链接")
                        }
                    }
                }
            }
        } else {
            if race.settle(success: false) {
                failToSwitch("该音源无法获取播放链接")
            }
        }

        // v1.0.95：2.5s 宽限后仍无结果 → 提前启动跨源兜底（与直接取链并行，谁先有效谁播）。
        // 桌面端体感「源挂了 1 秒切其他源」，是因为它的兜底不等当前源超时；
        // 旧版要等本源竞速全部失败（最长 ~13s）才开始换源，坏源歌曲始终慢。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, generation == self.playGeneration, !self.playbackCommitted else { return }
            Logger.info("LX PlayerManager: 直接取链 2.5s 未果，提前启动跨源兜底")
            self.handlePlayFailure(
                song: song,
                reason: "正在其他音源查找这首歌",
                generation: generation,
                completion: { _ in }
            )
        }
    }

    /// 真正把 item 挂上播放器
    private func startPlayback(url: URL, song: Song) {
        // v1.0.95：本代已开播（提前跨源兜底或直接取链先到者）→ 其余竞速结果作废
        guard !playbackCommitted else { return }
        Logger.info("开始播放: \(song.name) - \(song.singer) [\(currentSource)]")

        // v1.0.84：入口统一拦截 —— 覆盖「内置源 / LX 兼容层 / 自动换源」所有取链路径
        // （v1.0.90 起内置与 LX 并行竞速，两路的链接都经过这里）。命中已知试用/赞助版
        // 音源 id 或伪造链接时拒绝播放，交给 handlePlayFailure 换下一个候选源。
        let suspect = SourceGuard.isBlockedSource(currentSource)
            || SourceGuard.isBlockedSource(song.source)
            || SourceGuard.isForgedUrl(url.absoluteString)
        // 同步给 readyToPlay 的 duration<25s 兜底：换源/兜底链路同样启用短音频检测
        suspectCurrentSource = suspect
        if suspect {
            Logger.warn("LX PlayerManager: startPlayback 拦截试用音源链接 (\(currentSource) / \(url.absoluteString.prefix(60)))")
            if let song = currentSong {
                handlePlayFailure(song: song, reason: "该音源为试用/赞助版，已为你切换其他音源", completion: { _ in })
            }
            return
        }

        // v1.0.94：时长一致性预检 —— 桌面同步歌带权威时长（interval）。音源对某个
        // songmid 直接返回错音频（翻唱/错版顶号）是链接层检测不到的盲区，但音频
        // 时长会露馅（错版与目标普遍差几十秒）。出声前用 AVURLAsset 探时长，
        // 偏差超过 max(12s, 目标10%) → 拦截并走换源链；拿不到时长则放行不卡。
        if song.interval > 0 {
            verifyDurationThenStart(url: url, song: song)
            return
        }
        commitStartPlayback(url: url, song: song)
    }

    /// v1.0.94：出声前时长校验。4 秒内探不到时长就放行（宁慢勿卡）。
    private func verifyDurationThenStart(url: URL, song: Song) {
        let generation = playGeneration
        let expected = TimeInterval(song.interval)
        let tolerance = max(12.0, expected * 0.10)
        let asset = AVURLAsset(url: url)
        var finished = false
        let decide: (Bool) -> Void = { [weak self] ok in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                guard let self = self, generation == self.playGeneration else { return }
                if ok {
                    self.commitStartPlayback(url: url, song: song)
                } else {
                    Logger.warn("LX PlayerManager: 音频时长与目标不符（目标 \(Int(expected))s），拦截错版音频并换源")
                    self.handlePlayFailure(
                        song: song,
                        reason: "音源返回的音频与歌曲时长不符，已拦截并尝试其他音源",
                        generation: generation,
                        completion: { _ in }
                    )
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { decide(true) }
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "duration", error: &error)
            let d = status == .loaded ? CMTimeGetSeconds(asset.duration) : -1
            DispatchQueue.main.async {
                if d.isFinite && d > 0 {
                    decide(abs(d - expected) <= tolerance)
                } else {
                    decide(true)
                }
            }
        }
    }

    private func commitStartPlayback(url: URL, song: Song) {
        // v1.0.95：标记本代已开播；清掉兜底阶段挂出的过渡性错误提示
        playbackCommitted = true
        lastPlayError = nil
        // 先移除上一个播放项的观察者，避免其释放后被观察而崩溃
        if let old = observedItem {
            removeObservers(from: old)
        }

        let item = AVPlayerItem(url: url)

        // 在 addObserver 之前先把 observedItem 指向新项：
        // 这样 .initial 同步 KVO 也能正确命中「当前项」判定。
        observedItem = item

        item.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status),
            options: [.new, .initial],
            context: nil
        )
        item.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.duration),
            options: [.new],
            context: nil
        )

        player.replaceCurrentItem(with: item)
        // v1.0.112：开播前确保会话激活（mediaserverd 重启/中断后 session 可能仍反激活）
        ensureAudioSessionActive()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        fetchLyrics()
        fetchArtwork()
        notifyStateChanged()
        verifyResumeStarted()
    }

    /// 把音源返回的原始报错转成更易读的中文
    private func friendlyReason(_ raw: String) -> String {
        if raw.contains("仅") && (raw.contains("客户端") || raw.contains("App") || raw.contains("手机端")) {
            return "该歌曲需对应音乐客户端才能播放，已为你尝试其他音源"
        }
        if raw.contains("应用市场") || raw.contains("超低价") {
            return "该歌曲暂无法在本机音源播放，已为你尝试其他音源"
        }
        return raw
    }

    /// 播放失败统一处理：按设置决定是否自动换源
    private func handlePlayFailure(
        song: Song,
        reason: String,
        generation: Int? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        // v1.0.88：切歌后旧失败链路不再换源（generation 为 nil 的调用点来自
        // readyToPlay 短音频兜底等「当前歌仍然有效」的场景，不受限）
        if let generation = generation, generation != playGeneration { return }

        let reason = friendlyReason(reason)
        let sourceName = ConfigStore.shared.displayName(for: currentSource)

        guard ConfigStore.shared.autoSwitchSource, !isSwitchingSource else {
            lastPlayError = "\(sourceName)：\(reason)"
            isPlaying = false
            notifyStateChanged()
            completion(false)
            return
        }

        isSwitchingSource = true
        lastPlayError = "\(sourceName) 失败，正在尝试其他音源…"
        notifyStateChanged()

        sourceSwitcher.findPlayable(
            name: song.name,
            singer: song.singer,
            excluding: [currentSource],
            quality: ConfigStore.shared.defaultQuality,
            interval: song.interval
        ) { [weak self] hit in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isSwitchingSource = false

                // v1.0.88：换源期间用户又切了歌 → 本次结果作废
                if let generation = generation, generation != self.playGeneration { return }

                guard let hit = hit, let playUrl = URL(string: hit.url) else {
                    self.lastPlayError = "\(sourceName)：\(reason)（其他音源也未找到）"
                    self.isPlaying = false
                    // v1.0.88：彻底失败时把旧音频从播放器上摘掉——否则播放页显示的
                    // 是新歌、点播放键 resume 的却是上一首的音频（名实不符）。
                    if let old = self.observedItem {
                        self.removeObservers(from: old)
                        self.observedItem = nil
                    }
                    self.player.replaceCurrentItem(with: nil)
                    self.notifyStateChanged()
                    completion(false)
                    return
                }

                // 换源成功：切换当前源与当前歌曲元数据（songmid 属于新源）
                // v1.0.83：用 withDisplay 保留「歌单里的原名/歌手」展示，播放链接仍是
                // 新源匹配到的版本——否则换到 live/翻唱版时播放页名字也跟着变，用户
                // 会误以为播错了歌。id/songmid 保持新源版本不变（后续切歌/收藏以它为准）。
                let displaySong = hit.song.withDisplay(name: song.name, singer: song.singer)
                self.currentSource = hit.source
                self.currentSong = displaySong
                self.lastPlayError = nil
                self.onSongChanged?(displaySong)

                let newName = ConfigStore.shared.displayName(for: hit.source)
                Logger.info("已自动换源到 \(newName)（保留原名显示）")

                self.startPlayback(url: playUrl, song: displaySong)
                completion(true)
            }
        }
    }

    // MARK: - KVO

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        // KVO 可能由 AVFoundation 在后台线程回调，而切歌时会改写 observedItem（主线程）。
        // 统一把「身份判定 + 处理」派发到主线程，杜绝跨线程读写 observedItem 造成的独占访问崩溃。
        let handle: () -> Void = { [weak self] in
            guard let self = self, item === self.observedItem else { return }

            if keyPath == #keyPath(AVPlayerItem.status) {
                switch item.status {
                case .readyToPlay:
                    let dur = PlayerManager.sane(item.duration.seconds)
                    // v1.0.78 兜底：已知试用音源若返回的是极短 TTS 音频（<25s），立即换源，
                    // 不再把它当正版歌曲放出来（链接层拦截万一漏判时的最后一道防线）
                    if self.suspectCurrentSource, dur > 0, dur < 25 {
                        Logger.warn("LX PlayerManager: 检测到试用音源短音频(\(dur)s)，换源")
                        self.suspectCurrentSource = false
                        self.player.pause()
                        if let song = self.currentSong {
                            self.handlePlayFailure(song: song, reason: "试用音源，已切换其他音源", completion: { _ in })
                        }
                        return
                    }
                    self.duration = dur
                    self.onTimeChanged?(self.currentTime, self.duration)
                case .failed:
                    let reason = item.error?.localizedDescription ?? "链接无法播放"
                    Logger.error("播放项状态失败: \(reason)")
                    // 关键：失败时把时间轴清零，否则残留 NaN 会在下一次
                    // updateNowPlayingInfo / 进度条计算时引发崩溃
                    self.duration = 0
                    self.currentTime = 0
                    self.isPlaying = false
                    self.onTimeChanged?(0, 0)

                    if let song = self.currentSong {
                        // 链接拿到了但播不动（防盗链/地域限制/试听片段失效）→ 同样尝试换源
                        self.handlePlayFailure(song: song, reason: "链接无法播放") { _ in }
                    } else {
                        self.lastPlayError = "播放器无法播放该链接（可能源失效或地域限制）"
                        self.notifyStateChanged()
                    }
                default:
                    break
                }
            } else if keyPath == #keyPath(AVPlayerItem.duration) {
                self.duration = PlayerManager.sane(item.duration.seconds)
                // v1.0.76：duration 首次确定时把真实值推给锁屏 / 控制中心，
                // 否则 MPMediaItemPropertyPlaybackDuration 一直停在 0，
                // 锁屏进度条会「卡死不动」且无法拖动快进（系统无 duration 无法映射 scrub）。
                if self.duration > 0 {
                    Logger.info("LX PlayerManager: nowPlaying duration pushed")
                    self.updateNowPlayingInfo()
                }
                self.onTimeChanged?(self.currentTime, self.duration)
            }
        }

        if Thread.isMainThread {
            handle()
        } else {
            DispatchQueue.main.async { handle() }
        }
    }

    // MARK: - 时间更新

    private func handleTimeUpdate(_ time: CMTime) {
        currentTime = PlayerManager.sane(time.seconds)

        // 更新锁屏信息（NaN 会让 MPNowPlayingInfoCenter 抛异常，必须过滤）
        if isPlaying {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        onTimeChanged?(currentTime, duration)
        NotificationCenter.default.post(
            name: .playerTimeChanged,
            object: nil,
            userInfo: ["current": currentTime, "duration": duration]
        )
        updateLyrics()
    }

    // MARK: - 歌词

    private func fetchLyrics() {
        guard let song = currentSong else { return }

        // v1.0.124：换歌先清空旧歌词并广播（否则拉词期间悬浮窗残留上一首的句子）
        currentLyrics = []
        currentLyricIndex = -1
        NotificationCenter.default.post(name: .lyricsLoaded, object: nil)

        ScriptEngine.shared.getLyrics(
            source: currentSource,
            songId: song.songmid,
            extra: song.meta ?? [:]
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if case .success(let lrcText) = result, !lrcText.isEmpty {
                    self.currentLyrics = LRCParser.parse(lrcText)
                    self.currentLyricIndex = -1
                    self.onLyricsChanged?(-1, self.currentLyrics)
                    Logger.info("歌词加载完成: \(self.currentLyrics.count) 行")
                } else {
                    Logger.warn("无歌词")
                    self.currentLyrics = []
                }
                // v1.0.124：歌词状态落定，通知悬浮窗刷新（新歌第一句 / 歌名占位）
                NotificationCenter.default.post(name: .lyricsLoaded, object: nil)
            }
        }
    }

    private func updateLyrics() {
        guard !currentLyrics.isEmpty else { return }

        if let newIndex = LRCParser.findCurrentIndex(at: currentTime, in: currentLyrics) {
            if newIndex != currentLyricIndex {
                currentLyricIndex = newIndex
                onLyricsChanged?(newIndex, currentLyrics)

                // 通知悬浮歌词（带 index，供三行歌词取上/下句）
                NotificationCenter.default.post(
                    name: .lyricsLineChanged,
                    object: currentLyrics[newIndex],
                    userInfo: ["index": newIndex]
                )
            }
        }
    }

    // MARK: - 封面

    private func fetchArtwork() {
        guard let song = currentSong else { return }

        if let imgUrl = song.imgUrl, !imgUrl.isEmpty {
            loadArtwork(from: imgUrl)
        } else {
            // 搜索结果无封面时，通过音源脚本获取
            ScriptEngine.shared.getPic(
                source: song.source,
                songId: song.songmid,
                extra: song.meta ?? [:]
            ) { [weak self] result in
                if case .success(let url) = result, !url.isEmpty {
                    DispatchQueue.main.async {
                        self?.loadArtwork(from: url)
                    }
                }
            }
        }
    }

    private func loadArtwork(from urlString: String) {
        NetworkManager.shared.loadImage(url: urlString) { [weak self] data in
            guard let data = data, let image = UIImage(data: data) else { return }
            self?.currentArtwork = image

            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info

            // 通知 UI 更新封面
            NotificationCenter.default.post(
                name: .artworkLoaded,
                object: image
            )
        }
    }

    // MARK: - 锁屏信息

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }

        // 所有时间值必须是有限数 —— 传 NaN 给锁屏信息中心会直接崩溃
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.singer,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: PlayerManager.sane(currentTime),
            MPMediaItemPropertyPlaybackDuration: PlayerManager.sane(duration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let album = song.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 远程控制

    private func setupRemoteCommand() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    // MARK: - 播放结束

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        handlePlaybackEnded(reason: "播放结束通知")
    }

    // MARK: - 自动切歌（v1.0.103 加保险丝）

    /// 上次自动切歌的时间，用于 2 秒内防重复触发（通知 + 保险丝可能同时到达）
    private var lastAutoAdvanceAt: Date?
    private var endFuseTimer: Timer?

    /// 每秒检查一次「已经播到结尾，但 AVPlayerItemDidPlayToEndTime 没送达」的情况。
    /// 部分音源（尤其是换源得到的流）播完不发送结束通知，旧版就会「播完停住不下一首」。
    private func startPlaybackEndFuse() {
        guard endFuseTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkPlaybackEndFuse()
        }
        RunLoop.main.add(timer, forMode: .common)
        endFuseTimer = timer
    }

    private func checkPlaybackEndFuse() {
        guard isPlaying, duration > 1 else { return }
        guard duration - currentTime <= 0.8 else { return }
        // 网络缓冲导致的暂停不算播完，避免误切
        if let item = player.currentItem, player.rate == 0, !item.isPlaybackLikelyToKeepUp { return }
        handlePlaybackEnded(reason: "结尾保险丝")
    }

    /// 自动切歌统一入口
    private func handlePlaybackEnded(reason: String) {
        if let last = lastAutoAdvanceAt, Date().timeIntervalSince(last) < 2 {
            Logger.info("自动切歌：2 秒内已处理，忽略重复触发（\(reason)）")
            return
        }
        lastAutoAdvanceAt = Date()
        Logger.info("自动切歌（\(reason)）：模式=\(playMode.displayName) 队列=\(playQueue.count) 下标=\(queueIndex)")

        switch playMode {
        case .singleRepeat:
            seek(to: 0)
            resume()
        case .listRepeat:
            next()
        case .listOrder:
            if queueIndex < playQueue.count - 1 {
                next()
            } else {
                isPlaying = false
                notifyStateChanged()
            }
        case .random:
            next()
        }
    }

    // MARK: - 状态通知

    private func notifyStateChanged() {
        let state = PlayerState(
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            currentSong: currentSong,
            currentSource: currentSource,
            playMode: playMode,
            lyricIndex: currentLyricIndex,
            totalLyrics: currentLyrics.count
        )
        onStateChanged?(state)
        // 广播给所有观察者（迷你播放条、锁屏组件等），避免被播放页的闭包覆盖
        NotificationCenter.default.post(name: .playerStateChanged, object: state)
    }

    // MARK: - 队列管理

    var currentQueue: [Song] {
        return playQueue
    }

    var currentQueueIndex: Int {
        return queueIndex
    }

    func playAll(_ songs: [Song], from index: Int = 0) {
        guard !songs.isEmpty else { return }
        playQueue = songs
        // 夹紧下标，避免调用方传入越界值导致崩溃
        queueIndex = max(0, min(index, songs.count - 1))
        play(song: songs[queueIndex])
        postQueueChanged()
    }

    func addToQueue(_ song: Song) {
        // 去重：同一首歌（按 id）已在队列里就跳过，
        // 避免详情页重复点「加入队列」或「全部播放」时队列被反复加长
        if playQueue.contains(where: { $0.id == song.id }) {
            return
        }
        playQueue.append(song)
        postQueueChanged()
    }

    /// 清空当前播放队列（不停止当前播放）。详情页点「全部播放」时调用，
    /// 确保旧队列被清掉，只播放这个歌单的曲目。
    func clearQueue() {
        playQueue.removeAll()
        queueIndex = 0
        postQueueChanged()
    }

    /// 从队列移除指定位置（同步维护当前播放下标）
    func removeFromQueue(at index: Int) {
        guard index >= 0, index < playQueue.count else { return }
        playQueue.remove(at: index)
        if index < queueIndex {
            queueIndex = max(0, queueIndex - 1)
        } else if index == queueIndex {
            if queueIndex >= playQueue.count {
                queueIndex = max(0, playQueue.count - 1)
            }
        }
        postQueueChanged()
    }

    /// 移动队列中某首歌到新位置（同步维护当前播放下标）
    func moveQueueItem(from: Int, to: Int) {
        guard from != to, from >= 0, from < playQueue.count,
              to >= 0, to < playQueue.count else { return }
        let moved = playQueue.remove(at: from)
        playQueue.insert(moved, at: to)
        if from < queueIndex, to >= queueIndex {
            queueIndex -= 1
        } else if from > queueIndex, to <= queueIndex {
            queueIndex += 1
        } else if from == queueIndex {
            queueIndex = to
        }
        postQueueChanged()
    }

    private func postQueueChanged() {
        NotificationCenter.default.post(name: .playerQueueChanged, object: nil)
    }

    // MARK: - 清理

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let item = observedItem {
            removeObservers(from: item)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - PlayerState

struct PlayerState {
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let currentSong: Song?
    let currentSource: String
    let playMode: PlayMode
    let lyricIndex: Int
    let totalLyrics: Int
}

// MARK: - 通知名称

extension Notification.Name {
    static let lyricsLineChanged = Notification.Name("LyricsLineChanged")
    /// v1.0.124：歌词状态落定（换歌清空 / 解析完成 / 无歌词）
    static let lyricsLoaded = Notification.Name("MoshouMusicLyricsLoaded")
    static let artworkLoaded = Notification.Name("ArtworkLoaded")
    static let playerStateChanged = Notification.Name("PlayerStateChanged")
    static let playerTimeChanged = Notification.Name("PlayerTimeChanged")
    static let playerQueueChanged = Notification.Name("PlayerQueueChanged")
}
