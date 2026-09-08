import Foundation

/// 歌单存储 — JSON 文件存储，支持增删改查
class PlaylistStore {

    static let shared = PlaylistStore()

    private(set) var playlists: [Playlist] = []

    // 通知名称
    static let didChangeNotification = Notification.Name("PlaylistStoreDidChange")

    private init() {
        load()
    }

    // MARK: - 加载/保存

    private func load() {
        let path = ConfigStore.shared.playlistsPath

        guard FileManager.default.fileExists(atPath: path.path) else {
            // 首次启动，创建默认歌单
            createDefaultPlaylists()
            return
        }

        do {
            let data = try Data(contentsOf: path)
            playlists = try JSONDecoder().decode([Playlist].self, from: data)
            migrateLXSongmidIfNeeded()
        } catch {
            Logger.error("加载歌单失败: \(error)")
            createDefaultPlaylists()
        }
    }

    // MARK: - v1.0.91 存量迁移：修复同步歌曲的 songmid 身份

    /// 旧版同步把 LX 内部 id（kw_568484086 / 573841230_D7FF5208…）当成 songmid 落库，
    /// 导致所有直接取链失败。升级后按同一规则修复一遍存量数据（只跑一次）。
    private func migrateLXSongmidIfNeeded() {
        guard !ConfigStore.shared.lxSongmidFixV1Done else { return }
        ConfigStore.shared.lxSongmidFixV1Done = true

        var repaired = 0
        for plIdx in playlists.indices {
            for sIdx in playlists[plIdx].songs.indices {
                if let fixed = Self.repairSongmid(playlists[plIdx].songs[sIdx]) {
                    playlists[plIdx].songs[sIdx] = fixed
                    repaired += 1
                }
            }
        }
        if repaired > 0 {
            Logger.info("LX Sync: 存量歌曲 songmid 身份修复完成，共 \(repaired) 首")
            save()
        }
    }

    /// 单首修复：坏 songmid → 平台 songmid。无问题返回 nil。
    static func repairSongmid(_ song: Song) -> Song? {
        var meta = song.meta ?? [:]
        let source = song.source
        var songmid = song.songmid

        // kw/tx/wy/mg：id 带 "{source}_" 前缀
        let prefix = source + "_"
        if songmid.hasPrefix(prefix) {
            songmid = String(songmid.dropFirst(prefix.count))
        }
        // kg：复合 id "{audioId}_{hash32}" → 取 hash；hash 必须在 meta 里补齐
        if source == "kg" {
            if meta["hash"] == nil, let idx = songmid.firstIndex(of: "_") {
                let tail = String(songmid[songmid.index(after: idx)...])
                if tail.count == 32, tail.allSatisfy({ $0.isHexDigit }) {
                    meta["hash"] = tail
                    if songmid.contains("_") {
                        let audioId = String(songmid[..<idx])
                        if !audioId.isEmpty { meta["albumAudioId"] = audioId }
                    }
                    songmid = tail
                }
            }
            if songmid.count != 32, let sid = meta["songId"], sid.count == 32 {
                meta["hash"] = sid
                songmid = sid
            }
        }

        let metaChanged = (meta["hash"] ?? "") != (song.meta?["hash"] ?? "")
        guard songmid != song.songmid || metaChanged else { return nil }
        return Song(id: Song.makeId(source: source, songmid: songmid),
                    name: song.name, singer: song.singer, source: source,
                    songmid: songmid, albumName: song.albumName, albumId: song.albumId,
                    imgUrl: song.imgUrl, quality: song.quality, interval: song.interval,
                    meta: meta.isEmpty ? nil : meta)
    }

    func save() {
        let path = ConfigStore.shared.playlistsPath

        do {
            let data = try JSONEncoder().encode(playlists)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
        } catch {
            Logger.error("保存歌单失败: \(error)")
        }

        // 通知统一在主线程派发：LX 同步路径会在后台线程调用 save()，
        // 若在此直接 post，观察者（如歌单列表 reload）会在后台线程修改布局引擎而崩溃。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: nil)
        }
    }

    // MARK: - 默认歌单

    /// 「最近播放」歌单的固定名称。createDefaultPlaylists 用它建空壳；
    /// recordPlayed 也按这个名字查找/创建。所有「最近播放」逻辑只能写在这里，
    /// 避免别处散落硬编码字符串导致改名字后两边对不上。
    static let recentPlayedName = "最近播放"

    /// 「我的收藏」歌单的固定名称。LX 同步把 loveList（我喜欢）按此名映射到本歌单，
    /// 避免与同步生成的「我喜欢」歌单重复。所有相关逻辑只引用此常量。
    static let collectionName = "我的收藏"

    /// 「最近播放」保留的最大条数。手机端没必要无上限，100 首够日常用，
    /// 也避免 JSON 文件被无限撑大。
    static let recentPlayedMax = 100

    private func createDefaultPlaylists() {
        playlists = [
            Playlist(name: "我的收藏", songs: []),
            Playlist(name: Self.recentPlayedName, songs: []),
        ]
        save()
    }

    // MARK: - 最近播放（v1.0.71 修复）

    /// 记录一首被播放的歌：插入到「最近播放」**最前**、按 id 去重、超过上限裁尾。
    /// 调用方应在每次真正切到一首新歌时调一次（PlayerManager.play(song:) 已 hook），
    /// 用户手动播/上一首/下一首/列表播完自动 next 全覆盖。
    func recordPlayed(_ song: Song) {
        let target = Self.recentPlayedName
        if let index = playlists.firstIndex(where: { $0.name == target }) {
            // 去重：先把同 id 的旧记录删掉
            playlists[index].songs.removeAll { $0.id == song.id }
            // 插到最前
            playlists[index].songs.insert(song, at: 0)
            // 上限裁剪
            if playlists[index].songs.count > Self.recentPlayedMax {
                playlists[index].songs = Array(playlists[index].songs.prefix(Self.recentPlayedMax))
            }
            playlists[index].updatedAt = Date()
        } else {
            // 正常情况不会进这里（createDefaultPlaylists 已建好）；
            // 兜底：用户可能手动删过「最近播放」，重建一条单元素歌单
            playlists.append(Playlist(name: target, songs: [song]))
        }
        save()
    }

    // MARK: - 增删改查

    /// 创建歌单
    @discardableResult
    func create(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        save()
        return playlist
    }

    /// 直接加入一个已构造好的歌单（歌单导入用）
    func add(_ playlist: Playlist) {
        playlists.append(playlist)
        save()
    }

    /// 批量加入歌曲（歌单导入用，仅一次 save）
    func addSongs(_ songs: [Song], to playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        for song in songs where !playlists[index].songs.contains(where: { $0.id == song.id }) {
            playlists[index].songs.append(song)
        }
        playlists[index].updatedAt = Date()
        save()
    }

    /// 用新曲目整体替换歌单的歌曲（手动更新在线歌单用）
    func replaceSongs(_ songs: [Song], in playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].songs = songs
        playlists[index].updatedAt = Date()
        save()
    }

    /// 删除歌单
    func delete(id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// 重命名
    func rename(id: String, name: String) {
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            playlists[index].name = name
            playlists[index].updatedAt = Date()
            save()
        }
    }

    /// 添加歌曲到歌单
    func addSong(_ song: Song, to playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }

        // 去重
        if !playlists[index].songs.contains(where: { $0.id == song.id }) {
            playlists[index].songs.append(song)
            playlists[index].updatedAt = Date()
            save()
        }
    }

    /// 从歌单移除歌曲
    func removeSong(songId: String, from playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }

        playlists[index].songs.removeAll { $0.id == songId }
        playlists[index].updatedAt = Date()
        save()
    }

    /// 获取歌单
    func get(id: String) -> Playlist? {
        return playlists.first { $0.id == id }
    }

    /// 移动歌曲顺序
    func moveSong(in playlistId: String, from: Int, to: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let song = playlists[index].songs.remove(at: from)
        playlists[index].songs.insert(song, at: to)
        playlists[index].updatedAt = Date()
        save()
    }

    // MARK: - LX 导入合并

    /// 合并一批歌曲到指定名称的歌单：不存在则新建，存在则追加去重后的歌曲，整体只保存一次。
    /// 返回本次新增加的歌曲数。供 LXPlaylistBridge 导入使用。
    @discardableResult
    func mergeSongs(_ songs: [Song], intoPlaylistNamed name: String) -> Int {
        let unique = dedupe(songs)
        if let index = playlists.firstIndex(where: { $0.name == name }) {
            var added = 0
            for s in unique where !playlists[index].songs.contains(where: { $0.id == s.id }) {
                playlists[index].songs.append(s)
                added += 1
            }
            playlists[index].updatedAt = Date()
            save()
            return added
        } else {
            let pl = Playlist(name: name, songs: unique)
            playlists.append(pl)
            save()
            return unique.count
        }
    }

    /// LX 同步专用：在闭包内以可变形式访问歌单数组（自动保存并通知）
    func withMutablePlaylists(_ block: (inout [Playlist]) -> Void) {
        var copy = playlists
        block(&copy)
        playlists = copy
        save()
    }

    private func dedupe(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }
}
