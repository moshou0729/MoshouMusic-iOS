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
        } catch {
            Logger.error("加载歌单失败: \(error)")
            createDefaultPlaylists()
        }
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

        NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: nil)
    }

    // MARK: - 默认歌单

    private func createDefaultPlaylists() {
        playlists = [
            Playlist(name: "我的收藏", songs: []),
            Playlist(name: "最近播放", songs: []),
        ]
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
}
