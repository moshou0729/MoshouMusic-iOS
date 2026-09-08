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
    let id: String          // LX 内部缓存 id（kw_568484086 / 573841230_D7FF…），≠ 平台 songmid！
    let name: String
    let singer: String
    let source: String      // wy / tx / kg / mg
    let interval: String    // "mm:ss"
    var songmid: String?    // 平台 songmid（桌面端若下发则优先用）
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
        let imgUrl = meta?["picUrl"]?.stringValue
        let albumId = meta?["albumId"]?.stringValue

        // v1.0.91 重大修复：LX 的 `id` 是内部缓存 id，不是平台 songmid！
        // 实测桌面端 DB：kw 歌 id="kw_568484086"、kg 歌 id="573841230_D7FF5208…"。
        // 旧版直接 songmid=id → 所有直接取链（内置源+洛雪脚本）必然失败，
        // 每首歌都落入慢速搜索匹配（~10s）且版本经常不对（赤旗版播成原版）。
        // 还原规则：
        // - 优先用桌面端下发的 songmid 字段（若含）；
        // - kg：songmid 必须是 32 位 hash —— 取 meta.qualitys[0].hash（128k 档），
        //   否则从 id 尾部提取 32 位十六进制；audioId 部分存 meta.albumAudioId；
        // - kw/tx/wy/mg：songmid = meta.songId，否则剥掉 "{source}_" 前缀。
        var md = metaDict()
        let songmid = Self.resolveSongmid(id: id, source: source, songmidField: songmid,
                                          rawMeta: meta, meta: &md)

        return Song(
            id: Song.makeId(source: source, songmid: songmid),
            name: name, singer: singer, source: source, songmid: songmid,
            albumName: nil, albumId: albumId, imgUrl: imgUrl, quality: nil,
            interval: LXSyncModels.parseInterval(interval),
            meta: md.isEmpty ? nil : md
        )
    }

    /// 还原平台 songmid（详见 toSong 注释）。md 会被就地补写 hash/albumAudioId。
    static func resolveSongmid(id: String, source: String, songmidField: String?,
                               rawMeta: [String: JSONValue]?, meta: inout [String: String]) -> String {
        // ① 桌面端显式下发 songmid → 直接信任
        if let sm = songmidField, !sm.isEmpty { return sm }

        // ② kg：songmid = hash（32 位十六进制）
        if source == "kg" {
            // meta.qualitys[].hash（128k 档即可满足内置 kg.js 与 dujia）
            if case .array(let qs)? = rawMeta?["qualitys"] {
                for q in qs {
                    if case .object(let d)? = q, let h = d["hash"]?.stringValue,
                       h.count == 32, !h.isEmpty {
                        meta["hash"] = h
                        break
                    }
                }
            }
            if meta["hash"] == nil, let idx = id.firstIndex(of: "_") {
                let tail = String(id[id.index(after: idx)...])
                if tail.count == 32, tail.allSatisfy({ $0.isHexDigit }) {
                    meta["hash"] = tail
                }
            }
            if let audioId = meta["songId"] { meta["albumAudioId"] = audioId }
            if let h = meta["hash"], !h.isEmpty { return h }
        }

        // ③ 其他平台：songId → 剥 "{source}_" 前缀
        if let sid = meta["songId"], !sid.isEmpty { return sid }
        let prefix = source + "_"
        if id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
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
        if let meta = song.meta {
            for (k, v) in meta where m[k] == nil { m[k] = .string(v) }
        }
        // 对齐桌面端内部 id 约定：{source}_{songmid}
        let internalId = song.source + "_" + song.songmid
        return LXMusicInfo(
            id: internalId,
            name: song.name,
            singer: song.singer,
            source: song.source,
            interval: LXSyncModels.formatInterval(song.interval),
            songmid: song.songmid,
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
    /// ⚠️ 回传方向必须与落地方向一致（见 applyRemoteListData）：
    ///   defaultList ← 内置「最近播放」、loveList ← 内置「我的收藏」。
    static func getLocalListData() -> LXListData {
        let store = PlaylistStore.shared
        let defaultSongs = store.playlists.first(where: { $0.name == PlaylistStore.recentPlayedName })?.songs ?? []
        let loveSongs = store.playlists.first(where: { $0.name == PlaylistStore.collectionName })?.songs ?? []
        var userLists: [LXUserListInfoFull] = []
        for pl in store.playlists where pl.name != PlaylistStore.recentPlayedName && pl.name != PlaylistStore.collectionName {
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

    /// LX ListData -> 整体覆盖本机，按墨守music 内置歌单名映射（v1.0.74 起）：
    ///   LX loveList（我喜欢）  → 内置「我的收藏」
    ///   LX defaultList（默认列表）→ 内置「最近播放」
    ///   LX userList            → 各自原 id / 原名的歌单
    /// 兼容迁移：清掉旧版以 __lx_default__ / __lx_love__ 为 id 的残留歌单
    /// （即之前同步生成的「默认列表」「我喜欢」），避免与内置歌单重复出现。
    static func applyRemoteListData(_ data: LXListData) {
        let store = PlaylistStore.shared
        Logger.info("LX applyRemoteListData: love->我的收藏, default->最近播放 (userList=\(data.userList.count))")
        store.withMutablePlaylists { lists in
            // 迁移清理：删除旧映射残留（按 id 命中，不影响用户自建同名歌单）
            lists.removeAll { $0.id == LXListIDs.default || $0.id == LXListIDs.love }
            replaceOrCreateByName(name: PlaylistStore.collectionName,
                                  songs: data.loveList.map { $0.toSong() }, in: &lists)
            replaceOrCreateByName(name: PlaylistStore.recentPlayedName,
                                  songs: data.defaultList.map { $0.toSong() }, in: &lists)
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

    private static func replaceOrCreateByName(name: String, songs: [Song], in lists: inout [Playlist]) {
        if let idx = lists.firstIndex(where: { $0.name == name }) {
            lists[idx].songs = songs
            lists[idx].updatedAt = Date()
        } else {
            lists.append(Playlist(name: name, songs: songs))
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
