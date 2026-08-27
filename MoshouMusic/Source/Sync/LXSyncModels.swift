import Foundation

// MARK: - 容错 JSON 值（meta 中可能混入非字符串类型，避免整首歌解码失败）

/// 兼容服务端 meta 中可能出现的任意 JSON 值（字符串/数字/布尔/对象/数组/空）
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self)         { self = .array(v); return }
        throw DecodingError.typeMismatch(JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown JSON value"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .bool(let v):    try c.encode(v)
        case .null:           try c.encodeNil()
        case .object(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):  return String(format: "%g", n)
        case .bool(let b):    return b ? "true" : "false"
        default:              return nil
        }
    }
}

// MARK: - LX 同步数据模型（对齐 LX music.d.ts / sync.d.ts）

/// 单曲（LX 在线结构）
struct LXMusicInfo: Codable {
    let id: String          // 源内 ID（无 source 前缀）
    let name: String
    let singer: String
    let source: String      // wy / tx / kg / mg
    let interval: String    // "mm:ss"
    var meta: [String: JSONValue]?
}

/// 用户歌单（含完整歌曲列表）
struct LXUserListInfoFull: Codable {
    let id: String
    let name: String
    let source: String
    let sourceListId: String
    let locationUpdateTime: Int?
    let list: [LXMusicInfo]
}

/// 全量列表数据
struct LXListData: Codable {
    let defaultList: [LXMusicInfo]
    let loveList: [LXMusicInfo]
    let userList: [LXUserListInfoFull]
}

/// 客户端密钥信息（RSA 交换后服务端回传，存本地以便免码重连）
struct LXClientKeyInfo: Codable {
    let clientId: String
    let key: String   // AES key (base64)
    var serverName: String?
}

/// 各 action 的 payload 结构
struct LXListCreateData: Codable { let position: Int; let listInfos: [LXUserListInfoFull] }
struct LXListMusicData: Codable { let listId: String; let musicInfos: [LXMusicInfo] }
struct LXListMusicAddData: Codable { let id: String; let musicInfos: [LXMusicInfo]; let addMusicLocationType: String? }
struct LXListMusicRemoveData: Codable { let listId: String; let ids: [String] }
struct LXListMusicMoveData: Codable { let fromId: String; let toId: String; let musicInfos: [LXMusicInfo] }

/// 本机固定 id：对应 LX 的 default / love
enum LXListIDs {
    static let `default` = "__lx_default__"
    static let love = "__lx_love__"
}

// MARK: - 映射

extension LXMusicInfo {
    func toSong() -> Song {
        let songmid = id
        let imgUrl = meta?["picUrl"]?.stringValue
        let albumId = meta?["albumId"]?.stringValue
        return Song(
            id: Song.makeId(source: source, songmid: songmid),
            name: name, singer: singer, source: source, songmid: songmid,
            albumName: nil, albumId: albumId, imgUrl: imgUrl, quality: nil,
            interval: LXSyncModels.parseInterval(interval),
            meta: metaDict()
        )
    }

    private func metaDict() -> [String: String]? {
        guard let meta = meta else { return nil }
        var d = [String: String]()
        for (k, v) in meta { if let s = v.stringValue { d[k] = s } }
        return d.isEmpty ? nil : d
    }

    static func from(_ song: Song) -> LXMusicInfo {
        var m: [String: JSONValue] = [:]
        if let img = song.imgUrl { m["picUrl"] = .string(img) }
        if let a = song.albumId { m["albumId"] = .string(a) }
        m["songId"] = .string(song.songmid)
        return LXMusicInfo(
            id: song.songmid,
            name: song.name,
            singer: song.singer,
            source: song.source,
            interval: LXSyncModels.formatInterval(song.interval),
            meta: m.isEmpty ? nil : m
        )
    }
}

/// 服务端推送的增量 action（data 为任意 JSON 值）
struct LXListAction {
    let action: String
    let data: Any?
    init(action: String, data: Any?) {
        self.action = action
        self.data = data
    }
}

enum LXSyncModels {

    static func parseInterval(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return Int(s) ?? 0
    }

    static func formatInterval(_ sec: Int) -> String {
        String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    /// 把任意 JSON 值解码为目标 Codable 类型
    static func decode<T: Codable>(_ any: Any?) -> T? {
        guard let any = any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// 本机全量列表 -> LX ListData
    static func getLocalListData() -> LXListData {
        let store = PlaylistStore.shared
        let defaultSongs = store.get(id: LXListIDs.default)?.songs ?? []
        let loveSongs = store.get(id: LXListIDs.love)?.songs ?? []
        var userLists: [LXUserListInfoFull] = []
        for pl in store.playlists where pl.id != LXListIDs.default && pl.id != LXListIDs.love {
            userLists.append(LXUserListInfoFull(
                id: pl.id, name: pl.name, source: pl.source,
                sourceListId: pl.sourceListId,
                locationUpdateTime: Int(pl.updatedAt.timeIntervalSince1970),
                list: pl.songs.map { LXMusicInfo.from($0) }
            ))
        }
        return LXListData(
            defaultList: defaultSongs.map { LXMusicInfo.from($0) },
            loveList: loveSongs.map { LXMusicInfo.from($0) },
            userList: userLists
        )
    }

    /// 本机全量列表的 MD5（服务端用它判断是否与快照一致，决定是否需要重新合并）
    static func localListDataMD5() -> String {
        let data = getLocalListData()
        guard let encoded = try? JSONEncoder().encode(data) else { return "" }
        return Crypto.md5(encoded)
    }

    /// LX ListData -> 整体覆盖本机（default/love/user）
    static func applyRemoteListData(_ data: LXListData) {
        let store = PlaylistStore.shared
        store.withMutablePlaylists { lists in
            replaceOrCreate(id: LXListIDs.default, name: "默认列表",
                            songs: data.defaultList.map { $0.toSong() }, in: &lists)
            replaceOrCreate(id: LXListIDs.love, name: "我喜欢",
                            songs: data.loveList.map { $0.toSong() }, in: &lists)
            for ul in data.userList {
                let songs = ul.list.map { $0.toSong() }
                if let idx = lists.firstIndex(where: { $0.id == ul.id }) {
                    lists[idx].songs = songs
                    lists[idx].updatedAt = Date()
                } else {
                    lists.append(Playlist(id: ul.id, name: ul.name, source: ul.source,
                                         sourceListId: ul.sourceListId, songs: songs))
                }
            }
        }
    }

    private static func replaceOrCreate(id: String, name: String, songs: [Song], in lists: inout [Playlist]) {
        if let idx = lists.firstIndex(where: { $0.id == id }) {
            lists[idx].songs = songs
            lists[idx].updatedAt = Date()
        } else {
            lists.append(Playlist(id: id, name: name, songs: songs))
        }
    }

    // MARK: - 增量 action 应用（对齐 listEvent.ts handleRemoteListAction）

    static func applyAction(_ action: LXListAction) {
        let store = PlaylistStore.shared
        switch action.action {
        case "list_data_overwrite":
            if let d: LXListData = decode(action.data) { applyRemoteListData(d) }

        case "list_create":
            if let d: LXListCreateData = decode(action.data) {
                store.withMutablePlaylists { lists in
                    for info in d.listInfos {
                        let pl = Playlist(id: info.id, name: info.name, source: info.source,
                                         sourceListId: info.sourceListId,
                                         songs: info.list.map { $0.toSong() })
                        lists.append(pl)
                    }
                }
            }

        case "list_remove":
            if let ids = action.data as? [String] {
                for id in ids { store.delete(id: id) }
            }

        case "list_update":
            if let infos: [LXUserListInfoFull] = decode(action.data) {
                store.withMutablePlaylists { lists in
                    for info in infos {
                        if let idx = lists.firstIndex(where: { $0.id == info.id }) {
                            lists[idx].name = info.name
                            lists[idx].source = info.source
                            lists[idx].sourceListId = info.sourceListId
                            lists[idx].updatedAt = Date()
                        }
                    }
                }
            }

        case "list_music_overwrite":
            if let d: LXListMusicData = decode(action.data) {
                store.withMutablePlaylists { lists in
                    if let idx = lists.firstIndex(where: { $0.id == d.listId }) {
                        lists[idx].songs = d.musicInfos.map { $0.toSong() }
                        lists[idx].updatedAt = Date()
                    }
                }
            }

        case "list_music_add":
            if let d: LXListMusicAddData = decode(action.data) {
                for s in d.musicInfos.map({ $0.toSong() }) {
                    store.addSong(s, to: d.id)
                }
            }

        case "list_music_remove":
            if let d: LXListMusicRemoveData = decode(action.data) {
                if let _ = store.playlists.firstIndex(where: { $0.id == d.listId }) {
                    for sid in d.ids { store.removeSong(songId: sid, from: d.listId) }
                }
            }

        case "list_music_update":
            if let infos: [LXMusicInfo] = decode(action.data) {
                store.withMutablePlaylists { lists in
                    for info in infos {
                        let song = info.toSong()
                        for idx in lists.indices {
                            if let si = lists[idx].songs.firstIndex(where: { $0.id == song.id }) {
                                lists[idx].songs[si] = song
                            }
                        }
                    }
                }
            }

        case "list_music_clear":
            if let ids = action.data as? [String] {
                store.withMutablePlaylists { lists in
                    for id in ids {
                        if let idx = lists.firstIndex(where: { $0.id == id }) {
                            lists[idx].songs = []
                            lists[idx].updatedAt = Date()
                        }
                    }
                }
            }

        case "list_music_move":
            // {fromId, toId, musicInfos} —— 把歌曲合并进目标歌单
            if let d: LXListMusicMoveData = decode(action.data) {
                store.withMutablePlaylists { lists in
                    if let idx = lists.firstIndex(where: { $0.id == d.toId }) {
                        for s in d.musicInfos.map({ $0.toSong() })
                            where !lists[idx].songs.contains(where: { $0.id == s.id }) {
                            lists[idx].songs.append(s)
                        }
                        lists[idx].updatedAt = Date()
                    }
                }
            }

        case "list_update_position", "list_music_update_position":
            // 位置类动作手机端非必需，忽略（不影响数据内容）
            break

        default:
            Logger.error("LX 未知 list action: \(action.action)")
        }
    }
}
