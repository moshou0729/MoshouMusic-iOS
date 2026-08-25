import AVFoundation
import MediaPlayer
import Foundation

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
    private(set) var currentSource: String = "kw"
    private(set) var currentLyrics: [LRCLine] = []
    private(set) var currentLyricIndex: Int = -1

    /// 最近一次播放失败的原因（供播放页展示，便于排查是哪个源/哪一步失败）
    private(set) var lastPlayError: String?

    private(set) var playMode: PlayMode {
        get { PlayMode(rawValue: ConfigStore.shared.playMode) ?? .listRepeat }
        set { ConfigStore.shared.playMode = newValue.rawValue }
    }

    // MARK: - 私有

    private var player: AVPlayer!
    private var timeObserverToken: Any?
    /// KVO 上下文：必须是稳定且唯一的指针。
    /// 用 static let 持有一次分配的 UnsafeMutableRawPointer，避免用 `&实例属性` 传参——
    /// 后者会被 Swift 当作 modify 访问，而 AVFoundation 在 addObserver 时会同步触发 KVO，
    /// 造成 observeValue 内再次 `&` 访问同一存储 → 独占访问冲突 → swift_endAccess 崩溃。
    private static let playerItemContext: UnsafeMutableRawPointer = {
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    }()
    /// 当前正在观察的播放项，切歌前必须先移除其 KVO 观察者，否则旧项释放时会闪退
    private var observedItem: AVPlayerItem?

    private var playQueue: [Song] = []
    private var queueIndex: Int = 0

    private var sourceSwitcher: SourceSwitcher!
    private var isSwitchingSource = false

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
        if let queue = queue, !queue.isEmpty {
            playQueue = queue
            queueIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        }

        currentSong = song
        currentSource = song.source
        isSwitchingSource = false

        onSongChanged?(song)
        notifyStateChanged()

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

        // 借用 SourceSwitcher 的搜索+匹配+取链接流程，但只限定目标这一个源
        sourceSwitcher.findPlayable(
            name: song.name,
            singer: song.singer,
            excluding: Set(ConfigStore.shared.selectableSourceIds.filter { $0 != target }),
            quality: ConfigStore.shared.defaultQuality
        ) { [weak self] hit in
            guard let self = self else { return }
            DispatchQueue.main.async {
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
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), context: Self.playerItemContext)
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.duration), context: Self.playerItemContext)
    }

    private func loadAndPlay(completion: @escaping (Bool) -> Void) {
        guard let song = currentSong else {
            completion(false)
            return
        }

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

        ScriptEngine.shared.getMusicUrl(
            source: currentSource,
            songId: song.songmid,
            quality: ConfigStore.shared.defaultQuality,
            extra: song.meta ?? [:]
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let url):
                    guard let playUrl = URL(string: url) else {
                        Logger.error("无效的播放 URL: \(url)")
                        self.handlePlayFailure(song: song, reason: "播放链接无效", completion: completion)
                        return
                    }
                    self.startPlayback(url: playUrl, song: song)
                    completion(true)

                case .failure(let error):
                    Logger.error("获取播放链接失败[\(self.currentSource)]: \(error.localizedDescription)")
                    // 兜底：同平台的内置源失效时，尝试 LX 兼容层（洛雪社区脚本）的同源端点
                    self.tryLXCompatFallback(song: song, builtinError: error.localizedDescription, completion: completion)
                }
            }
        }
    }

    /// LX 兼容层兜底：内置源取不到播放链接时，用同平台的洛雪社区脚本再试一次
    private func tryLXCompatFallback(song: Song, builtinError: String, completion: @escaping (Bool) -> Void) {
        guard LXCompatEngine.shared.isPlatformAvailable(song.source) else {
            handlePlayFailure(song: song, reason: builtinError, completion: completion)
            return
        }
        Logger.info("尝试 LX 兼容层兜底: \(song.source)")
        let quality = ConfigStore.shared.defaultQuality
        let extra = song.meta ?? [:]
        LXCompatEngine.shared.getMusicUrl(
            platform: song.source,
            songId: song.songmid,
            quality: quality,
            extra: extra
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let url):
                    guard let playUrl = URL(string: url) else {
                        self.handlePlayFailure(song: song, reason: builtinError, completion: completion)
                        return
                    }
                    Logger.info("LX 兼容层兜底成功: \(song.source)")
                    self.startPlayback(url: playUrl, song: song)
                    completion(true)
                case .failure:
                    self.handlePlayFailure(song: song, reason: builtinError, completion: completion)
                }
            }
        }
    }

    /// 真正把 item 挂上播放器
    private func startPlayback(url: URL, song: Song) {
        Logger.info("开始播放: \(song.name) - \(song.singer) [\(currentSource)]")

        // 先移除上一个播放项的观察者，避免其释放后被观察而崩溃
        if let old = observedItem {
            removeObservers(from: old)
            observedItem = nil
        }

        let item = AVPlayerItem(url: url)

        item.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status),
            options: [.new, .initial],
            context: Self.playerItemContext
        )
        item.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.duration),
            options: [.new],
            context: Self.playerItemContext
        )

        observedItem = item
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        fetchLyrics()
        fetchArtwork()
        notifyStateChanged()
    }

    /// 播放失败统一处理：按设置决定是否自动换源
    private func handlePlayFailure(
        song: Song,
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
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

                guard let hit = hit, let playUrl = URL(string: hit.url) else {
                    self.lastPlayError = "\(sourceName)：\(reason)（其他音源也未找到）"
                    self.isPlaying = false
                    self.notifyStateChanged()
                    completion(false)
                    return
                }

                // 换源成功：切换当前源与当前歌曲元数据（songmid 属于新源）
                self.currentSource = hit.source
                self.currentSong = hit.song
                self.lastPlayError = nil
                self.onSongChanged?(hit.song)

                let newName = ConfigStore.shared.displayName(for: hit.source)
                Logger.info("已自动换源到 \(newName)")

                self.startPlayback(url: playUrl, song: hit.song)
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
        guard context == Self.playerItemContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        // 只观察当前挂载的 item，忽略已被替换掉的旧 item 的迟到通知
        guard let item = object as? AVPlayerItem, item === observedItem else { return }

        if keyPath == #keyPath(AVPlayerItem.status) {
            switch item.status {
            case .readyToPlay:
                duration = PlayerManager.sane(item.duration.seconds)
                onTimeChanged?(currentTime, duration)
            case .failed:
                let reason = item.error?.localizedDescription ?? "链接无法播放"
                Logger.error("播放项状态失败: \(reason)")
                // 关键：失败时把时间轴清零，否则残留 NaN 会在下一次
                // updateNowPlayingInfo / 进度条计算时引发崩溃
                duration = 0
                currentTime = 0
                isPlaying = false
                onTimeChanged?(0, 0)

                if let song = currentSong {
                    // 链接拿到了但播不动（防盗链/地域限制/试听片段失效）→ 同样尝试换源
                    handlePlayFailure(song: song, reason: "链接无法播放") { _ in }
                } else {
                    lastPlayError = "播放器无法播放该链接（可能源失效或地域限制）"
                    notifyStateChanged()
                }
            default:
                break
            }
        } else if keyPath == #keyPath(AVPlayerItem.duration) {
            duration = PlayerManager.sane(item.duration.seconds)
            onTimeChanged?(currentTime, duration)
        }
    }

    // MARK: - 时间更新

    private func handleTimeUpdate(_ time: CMTime) {
        currentTime = PlayerManager.sane(time.seconds)

        // 更新锁屏信息（NaN 会让 MPNowPlayingInfoCenter 抛异常，必须过滤）
        if isPlaying {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        onTimeChanged?(currentTime, duration)
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
    }

    func addToQueue(_ song: Song) {
        playQueue.append(song)
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
}
