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
        static let isDarkMode = "isDarkMode"
        static let cacheSize = "cacheSize"
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

    /// 所有可用源
    let allSources = ["kw", "tx", "mg", "wy", "kg"]

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

    // MARK: - 清理缓存

    func clearCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) {
            for file in files {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
            }
        }
    }
}
