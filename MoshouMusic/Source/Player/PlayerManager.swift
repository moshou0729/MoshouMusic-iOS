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

    private(set) var playMode: PlayMode {
        get { PlayMode(rawValue: ConfigStore.shared.playMode) ?? .listRepeat }
        set { ConfigStore.shared.playMode = newValue.rawValue }
    }

    // MARK: - 私有

    private var player: AVPlayer!
    private var timeObserverToken: Any?
    private var playerItemContext: Int = 0

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
            if !success && !self.isSwitchingSource {
                self.trySwitchSource()
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

        queueIndex = (queueIndex - 1 + playQueue.count) % playQueue.count
        play(song: playQueue[queueIndex])
    }

    /// 跳转
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: cmTime) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
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

    private func loadAndPlay(completion: @escaping (Bool) -> Void) {
        guard let song = currentSong else {
            completion(false)
            return
        }

        // 清理旧歌词
        currentLyrics = []
        currentLyricIndex = -1
        onLyricsChanged?(-1, [])

        notifyStateChanged()

        ScriptEngine.shared.getMusicUrl(
            source: currentSource,
            songId: song.songmid,
            quality: ConfigStore.shared.defaultQuality
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let url):
                    guard let playUrl = URL(string: url) else {
                        Logger.error("无效的播放 URL: \(url)")
                        completion(false)
                        return
                    }

                    Logger.info("开始播放: \(song.name) - \(song.singer) [\(self.currentSource)]")

                    let item = AVPlayerItem(url: playUrl)

                    // 监听状态
                    item.addObserver(
                        self,
                        forKeyPath: #keyPath(AVPlayerItem.status),
                        options: [.new, .initial],
                        context: &self.playerItemContext
                    )

                    // 监听时长
                    item.addObserver(
                        self,
                        forKeyPath: #keyPath(AVPlayerItem.duration),
                        options: [.new],
                        context: &self.playerItemContext
                    )

                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                    self.fetchLyrics()
                    self.fetchArtwork()
                    completion(true)

                case .failure(let error):
                    Logger.error("获取播放链接失败: \(error.localizedDescription)")
                    completion(false)
                }
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
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if keyPath == #keyPath(AVPlayerItem.status) {
            if let item = object as? AVPlayerItem {
                if item.status == .readyToPlay {
                    duration = item.duration.seconds
                    onTimeChanged?(currentTime, duration)
                } else if item.status == .failed {
                    Logger.error("播放项状态失败")
                    if !isSwitchingSource {
                        trySwitchSource()
                    }
                }
            }
        } else if keyPath == #keyPath(AVPlayerItem.duration) {
            if let item = object as? AVPlayerItem {
                duration = item.duration.seconds
                onTimeChanged?(currentTime, duration)
            }
        }
    }

    // MARK: - 自动换源

    private func trySwitchSource() {
        guard !isSwitchingSource else { return }
        isSwitchingSource = true

        sourceSwitcher.switchSource(
            currentSource: currentSource,
            availableSources: ConfigStore.shared.enabledSources
        ) { [weak self] newSource in
            guard let self = self else { return false }

            self.currentSource = newSource
            self.loadAndPlay { success in
                if success {
                    self.isSwitchingSource = false
                    Logger.info("换源成功: \(newSource)")
                }
            }
            // 简化：返回 true 开始尝试
            return true
        }
    }

    // MARK: - 时间更新

    private func handleTimeUpdate(_ time: CMTime) {
        currentTime = time.seconds

        // 更新锁屏信息
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

        ScriptEngine.shared.getLyrics(source: currentSource, songId: song.songmid) { [weak self] result in
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
        guard let song = currentSong, let imgUrl = song.imgUrl else { return }

        NetworkManager.shared.loadImage(url: imgUrl) { [weak self] data in
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

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.singer,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
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
        queueIndex = index
        play(song: songs[index])
    }

    func addToQueue(_ song: Song) {
        playQueue.append(song)
    }

    // MARK: - 清理

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
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
