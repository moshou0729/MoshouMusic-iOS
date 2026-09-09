import Foundation

/// 配置存储 — 管理应用设置和用户偏好
class ConfigStore {

    static let shared = ConfigStore()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let enabledSources = "enabledSources"
        static let defaultQuality = "defaultQuality"
        static let playMode = "playMode"
        static let volume = "volume"
        static let searchHistory = "searchHistory"
        static let isFloatingLyricsOn = "isFloatingLyricsOn"
        static let floatingOpacity = "floatingOpacity"
        static let floatingWidth = "floatingWidth"
        static let floatingHeight = "floatingHeight"
        static let floatingPosX = "floatingPosX"
        static let floatingPosY = "floatingPosY"
        static let floatingFontSize = "floatingFontSize"
        static let floatingBgColorHex = "floatingBgColorHex"
        static let isDarkMode = "isDarkMode"
        static let cacheSize = "cacheSize"
        static let currentSource = "currentSource"
        static let customSources = "customSources"
        static let autoSwitchSource = "autoSwitchSource"
        static let lxSyncServerURL = "lxSyncServerURL"
        static let lxSyncEnabled = "lxSyncEnabled"
        static let lxSyncMode = "lxSyncMode"
        static let lxLastSyncDate = "lxLastSyncDate"
        static let preferredLXScriptID = "preferredLXScriptID"
        static let lxSongmidFixV1Done = "lxSongmidFixV1Done"
    }

    // MARK: - 路径

    /// 文档目录
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 脚本目录
    var scriptsDirectory: URL {
        documentsDirectory.appendingPathComponent("scripts")
    }

    /// 下载目录
    var downloadsDirectory: URL {
        documentsDirectory.appendingPathComponent("downloads")
    }

    /// 歌词缓存目录
    var lyricsCacheDirectory: URL {
        documentsDirectory.appendingPathComponent("lyrics")
    }

    /// 歌单存储路径
    var playlistsPath: URL {
        documentsDirectory.appendingPathComponent("playlists.json")
    }

    // MARK: - 音源设置

    /// 所有可用源（酷我已移除 — 其音源返回的播放链接均无法播放）
    let allSources = ["tx", "mg", "wy", "kg"]

    /// 已启用的源
    var enabledSources: [String] {
        get {
            if let data = defaults.array(forKey: Keys.enabledSources) as? [String] {
                return data
            }
            return allSources // 默认全部启用
        }
        set {
            defaults.set(newValue, forKey: Keys.enabledSources)
        }
    }

    func isSourceEnabled(_ source: String) -> Bool {
        return enabledSources.contains(source)
    }

    func setSource(_ source: String, enabled: Bool) {
        var sources = enabledSources
        if enabled && !sources.contains(source) {
            sources.append(source)
        } else if !enabled {
            sources.removeAll { $0 == source }
        }
        enabledSources = sources
    }

    // MARK: - 当前选中源

    /// 当前搜索/播放使用的音源
    var currentSource: String {
        get { defaults.string(forKey: Keys.currentSource) ?? "kg" }
        set { defaults.set(newValue, forKey: Keys.currentSource) }
    }

    // MARK: - 自动换源

    /// 当前音源拿不到播放链接时，自动去其他音源找同一首歌
    /// 默认开启 —— 各平台风控频繁，单源失败是常态
    var autoSwitchSource: Bool {
        get {
            if defaults.object(forKey: Keys.autoSwitchSource) == nil { return true }
            return defaults.bool(forKey: Keys.autoSwitchSource)
        }
        set { defaults.set(newValue, forKey: Keys.autoSwitchSource) }
    }

    // MARK: - LX 首选音源脚本

    /// 用户偏好的洛雪社区脚本 id：取链/换源时它在同平台 provider 轮询里被置顶优先。
    /// 默认 "dujia"（独家音源v5）——若该脚本未成功注册（如 iOS 环境不兼容）则自动忽略，
    /// 不影响其它脚本；用户可在「洛雪社区音源」列表里改成任意已加载脚本。
    var preferredLXScriptID: String {
        get {
            if defaults.object(forKey: Keys.preferredLXScriptID) == nil { return "dujia" }
            return defaults.string(forKey: Keys.preferredLXScriptID) ?? "dujia"
        }
        set { defaults.set(newValue, forKey: Keys.preferredLXScriptID) }
    }

    // MARK: - LX Music 桌面版同步

    /// v1.0.91 一次性迁移标记：修复存量同步歌曲的 songmid（旧版把 LX 内部 id 当 songmid）
    var lxSongmidFixV1Done: Bool {
        get { defaults.bool(forKey: Keys.lxSongmidFixV1Done) }
        set { defaults.set(newValue, forKey: Keys.lxSongmidFixV1Done) }
    }

    /// 同步服务地址 (LX 桌面版 v2.4+ / 独立版 sync-server v2.0+)
    /// 格式: http://192.168.x.x:23332 或 https://example.com/lxsync
    var lxSyncServerURL: String {
        get { defaults.string(forKey: Keys.lxSyncServerURL) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lxSyncServerURL) }
    }

    /// 同步开关 (默认关 — 用户必须显式启用)
    var lxSyncEnabled: Bool {
        get { defaults.bool(forKey: Keys.lxSyncEnabled) }
        set { defaults.set(newValue, forKey: Keys.lxSyncEnabled) }
    }

    /// 同步模式偏好（实际合并/覆盖策略由桌面端在连接时选择，此为手机端建议值）
    /// 可选：merge_local_remote / merge_remote_local / overwrite_local_remote / overwrite_remote_local
    var lxSyncMode: String {
        get { defaults.string(forKey: Keys.lxSyncMode) ?? "merge_local_remote" }
        set { defaults.set(newValue, forKey: Keys.lxSyncMode) }
    }

    /// 上次成功同步时间
    var lxLastSyncDate: Date? {
        get { defaults.object(forKey: Keys.lxLastSyncDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lxLastSyncDate) }
    }

    // MARK: - 自定义音源 (本机手动添加)

    /// 自定义音源登记: [音源ID: 显示名]
    var customSources: [String: String] {
        get { defaults.dictionary(forKey: Keys.customSources) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.customSources) }
    }

    func addCustomSource(id: String, name: String) {
        var c = customSources
        c[id] = name
        customSources = c
    }

    func removeCustomSource(id: String) {
        var c = customSources
        c.removeValue(forKey: id)
        customSources = c
    }

    /// 全部可选音源 id（内置在前，自定义在后，去重）
    var selectableSourceIds: [String] {
        var ids = allSources
        for id in customSources.keys where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// 显示名（内置走 ScriptManager，自定义走登记名）
    func displayName(for source: String) -> String {
        if let name = customSources[source] { return name }
        return ScriptManager.shared.sourceDisplayName(source)
    }

    // MARK: - 播放设置

    /// 默认音质
    var defaultQuality: String {
        get { defaults.string(forKey: Keys.defaultQuality) ?? "320k" }
        set { defaults.set(newValue, forKey: Keys.defaultQuality) }
    }

    /// 播放模式
    var playMode: Int {
        get { defaults.integer(forKey: Keys.playMode) }
        set { defaults.set(newValue, forKey: Keys.playMode) }
    }

    /// 音量 (0.0 - 1.0)
    var volume: Float {
        get {
            let v = defaults.float(forKey: Keys.volume)
            return v == 0 ? 1.0 : v
        }
        set { defaults.set(newValue, forKey: Keys.volume) }
    }

    // MARK: - 搜索历史

    var searchHistory: [String] {
        get { defaults.array(forKey: Keys.searchHistory) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: Keys.searchHistory) }
    }

    func addSearchHistory(_ keyword: String) {
        var history = searchHistory.filter { $0 != keyword }
        history.insert(keyword, at: 0)
        if history.count > 20 {
            history = Array(history.prefix(20))
        }
        searchHistory = history
    }

    func clearSearchHistory() {
        searchHistory = []
    }

    // MARK: - 悬浮歌词设置

    var isFloatingLyricsOn: Bool {
        get { defaults.bool(forKey: Keys.isFloatingLyricsOn) }
        set { defaults.set(newValue, forKey: Keys.isFloatingLyricsOn) }
    }

    var floatingOpacity: Float {
        get {
            let v = defaults.float(forKey: Keys.floatingOpacity)
            return v == 0 ? 0.85 : v
        }
        set { defaults.set(newValue, forKey: Keys.floatingOpacity) }
    }

    /// 悬浮窗尺寸（默认 300 × 126）
    var floatingSize: CGSize {
        get {
            let w = defaults.float(forKey: Keys.floatingWidth)
            let h = defaults.float(forKey: Keys.floatingHeight)
            return CGSize(width: w == 0 ? 300 : CGFloat(w),
                          height: h == 0 ? 126 : CGFloat(h))
        }
        set {
            defaults.set(Float(newValue.width), forKey: Keys.floatingWidth)
            defaults.set(Float(newValue.height), forKey: Keys.floatingHeight)
        }
    }

    /// 悬浮窗左上角位置（默认右上角偏下）
    var floatingOrigin: CGPoint {
        get {
            let hasX = defaults.object(forKey: Keys.floatingPosX) != nil
            let hasY = defaults.object(forKey: Keys.floatingPosY) != nil
            let x = defaults.float(forKey: Keys.floatingPosX)
            let y = defaults.float(forKey: Keys.floatingPosY)
            if !hasX || !hasY {
                let screenW = UIScreen.main.bounds.width
                return CGPoint(x: max(8, screenW - floatingSize.width - 12), y: 140)
            }
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        set {
            defaults.set(Float(newValue.x), forKey: Keys.floatingPosX)
            defaults.set(Float(newValue.y), forKey: Keys.floatingPosY)
        }
    }

    /// 悬浮歌词字号（中间行，默认 16）
    var floatingFontSize: CGFloat {
        get {
            let v = defaults.float(forKey: Keys.floatingFontSize)
            return v == 0 ? 16 : CGFloat(v)
        }
        set { defaults.set(Float(newValue), forKey: Keys.floatingFontSize) }
    }

    /// 悬浮歌词背景颜色（RGB hex，如 0x000000 黑 / 0xFFFFFF 白；默认黑）
    var floatingBgColorHex: UInt32 {
        get {
            let v = defaults.object(forKey: Keys.floatingBgColorHex) as? Int
            return v.map(UInt32.init) ?? 0x000000
        }
        set { defaults.set(Int(newValue), forKey: Keys.floatingBgColorHex) }
    }

    /// 恢复默认位置与尺寸
    func resetFloatingLayout() {
        defaults.removeObject(forKey: Keys.floatingPosX)
        defaults.removeObject(forKey: Keys.floatingPosY)
        defaults.removeObject(forKey: Keys.floatingWidth)
        defaults.removeObject(forKey: Keys.floatingHeight)
        defaults.removeObject(forKey: Keys.floatingFontSize)
    }

    // MARK: - 外观设置

    var isDarkMode: Bool {
        get { defaults.bool(forKey: Keys.isDarkMode) }
        set { defaults.set(newValue, forKey: Keys.isDarkMode) }
    }

    // MARK: - 保存

    func save() {
        defaults.synchronize()
        Logger.debug("配置已保存")
    }

    // MARK: - 缓存

    /// 缓存目录（系统 Caches：URLCache / 图片 / 临时媒体等）。
    /// ⚠️「下载的音乐」在 Documents/downloads，属用户资产，**不算缓存、不会被自动清理**。
    var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// 缓存硬上限：1 GB（1024³ 字节）
    static let maxCacheBytes: Int64 = 1024 * 1024 * 1024

    /// 触发自动清理后回落到的水位（上限的 80%），避免写入一点点就反复触发全量清理
    static let cacheLowWaterBytes: Int64 = maxCacheBytes * 8 / 10

    /// 递归统计某个目录占用的字节数（只算普通文件）
    func folderSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 当前缓存大小（字节）
    func currentCacheBytes() -> Int64 {
        folderSize(at: cacheDirectory)
    }

    /// 字节数 → 人类可读（B / KB / MB / GB，1024 进制）
    static func formatBytes(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        if value < 1024 { return "\(value) B" }
        let kb = Double(value) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// 超过 1 GB 上限时按「最久未修改优先」自动清理，直到回落到低水位。
    /// - Returns: 本次释放的字节数（未超限则为 0）
    @discardableResult
    func enforceCacheLimit() -> Int64 {
        var total = currentCacheBytes()
        guard total > ConfigStore.maxCacheBytes else { return 0 }

        let fm = FileManager.default
        var files: [(url: URL, size: Int64, mtime: Date)] = []
        if let enumerator = fm.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ), values.isRegularFile == true, let size = values.fileSize else { continue }
                files.append((fileURL, Int64(size), values.contentModificationDate ?? .distantPast))
            }
        }

        // 最旧的先删（LRU），保证用户刚产生的缓存尽量保留
        files.sort { $0.mtime < $1.mtime }

        var freed: Int64 = 0
        for file in files {
            guard total > ConfigStore.cacheLowWaterBytes else { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
                freed += file.size
            }
        }

        if freed > 0 {
            Logger.info("ConfigStore: cache trimmed, freed \(ConfigStore.formatBytes(freed)) bytes")
        }
        return freed
    }

    /// 清空全部缓存
    func clearCache() {
        let cacheDir = cacheDirectory
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) {
            for file in files {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
            }
        }
    }
}
