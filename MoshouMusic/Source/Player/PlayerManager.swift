import AVFoundation
import MediaPlayer
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

    // MARK: - Init

    override init() {
        super.init()
        setupPlayer()
        setupRemoteCommand()
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
    }

    // MARK: - 播放控制

    /// 播放一首歌
    func play(song: Song, queue: [Song]? = nil) {
        // v1.0.88：作废上一条还在路上的取链链路（其 completion 会因令牌不符被丢弃）
        playGeneration += 1
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
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        notifyStateChanged()
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
        player.pause()
        isPlaying = false
        currentTime = 0

        // 借用 SourceSwitcher 的搜索+匹配+取链接流程，但只限定目标这一个源
        sourceSwitcher.findPlayable(
            name: song.name,
            singer: song.singer,
            excluding: Set(ConfigStore.shared.selectableSourceIds.filter { $0 != target }),
            quality: ConfigStore.shared.defaultQuality
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
    }

    /// 真正把 item 挂上播放器
    private func startPlayback(url: URL, song: Song) {
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
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        fetchLyrics()
        fetchArtwork()
        notifyStateChanged()
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
            quality: ConfigStore.shared.defaultQuality
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
            }
        }
    }

    private func updateLyrics() {
        guard !currentLyrics.isEmpty else { return }

        if let newIndex = LRCParser.findCurrentIndex(at: currentTime, in: currentLyrics) {
            if newIndex != currentLyricIndex {
                currentLyricIndex = newIndex
                onLyricsChanged?(newIndex, currentLyrics)

                // 通知悬浮歌词
                NotificationCenter.default.post(
                    name: .lyricsLineChanged,
                    object: currentLyrics[newIndex]
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
    static let artworkLoaded = Notification.Name("ArtworkLoaded")
    static let playerStateChanged = Notification.Name("PlayerStateChanged")
    static let playerTimeChanged = Notification.Name("PlayerTimeChanged")
    static let playerQueueChanged = Notification.Name("PlayerQueueChanged")
}
