import Foundation

/// LX 桌面版歌单 JSON 互导桥
///
/// Phase 1（本次交付）：文件互导 —— 把 LX 桌面版「导出」的歌单 JSON 导入本机，
/// 或把本机歌单导出为 LX 兼容 JSON。纯本地、可离线验证，不依赖实时连接。
/// 字段映射严格对齐 LX 在线歌曲模型（id / name / singer / source /
/// interval 为字符串 "mm:ss" / meta.{songId, picUrl, albumId}）。
///
/// Phase 2（后续）：基于 LX 原生 WebSocket RPC（message2call + AES-128-ECB）的
/// 实时双向同步，见 LXSyncService。
enum LXPlaylistBridge {

    /// 解析后的一个歌单（可能来自 LX 的 playlists / loveList / 单个 list）
    struct ImportPlaylist {
        let name: String
        let songs: [Song]
    }

    enum BridgeError: Error, LocalizedError {
        case notJSON
        case unrecognized(String)
        case empty
        var errorDescription: String? {
            switch self {
            case .notJSON: return "文件不是合法 JSON"
            case .unrecognized(let m): return "无法识别的 LX 文件格式：\(m)"
            case .empty: return "文件中没有可导入的歌曲"
            }
        }
    }

    // MARK: - 解析

    /// 解析 LX 导出的歌单 JSON，返回若干歌单
    static func parse(data: Data) throws -> [ImportPlaylist] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw BridgeError.notJSON
        }
        var result: [ImportPlaylist] = []

        if let arr = json as? [[String: Any]] {
            // 形状 A：纯歌曲数组
            let songs = songsFromArray(arr)
            if !songs.isEmpty { result.append(ImportPlaylist(name: "LX 导入", songs: songs)) }

        } else if let dict = json as? [String: Any] {
            // 形状 B：完整备份 { playlists:[...], loveList:[...], ... }
            if let lists = dict["playlists"] as? [[String: Any]] {
                for p in lists {
                    let name = nonEmpty(p["name"]) ?? "LX 歌单"
                    let songs = songsFromArray(p["list"] as? [Any] ?? p["musicList"] as? [Any])
                    if !songs.isEmpty { result.append(ImportPlaylist(name: name, songs: songs)) }
                }
            }
            if let love = dict["loveList"] as? [Any] {
                let songs = songsFromArray(love)
                if !songs.isEmpty { result.append(ImportPlaylist(name: "我喜欢 (LX)", songs: songs)) }
            }
            if let my = dict["myList"] as? [Any] {
                let songs = songsFromArray(my)
                if !songs.isEmpty { result.append(ImportPlaylist(name: "我的列表 (LX)", songs: songs)) }
            }
            // 形状 C：单个歌单 { source, name?, list:[...] }
            if let list = dict["list"] as? [Any], !list.isEmpty {
                let name = nonEmpty(dict["name"]) ?? nonEmpty(dict["source"]) ?? "LX 导入"
                let songs = songsFromArray(list)
                if !songs.isEmpty { result.append(ImportPlaylist(name: name, songs: songs)) }
            }
        } else {
            throw BridgeError.unrecognized("根节点既不是数组也不是对象")
        }

        if result.isEmpty { throw BridgeError.empty }
        return result
    }

    // MARK: - 编码（本机 → LX 兼容 JSON）

    // MARK: - .lxmc 解析（gzip 压缩的 JSON）

    /// 解析 LX 桌面版导出的文件（.lxmc 为 gzip 压缩的 JSON，.json 为纯 JSON）
    /// 先嗅探 gzip 魔数（0x1f 0x8b），命中则解压后再走通用解析
    static func parseLXMC(data: Data) throws -> [ImportPlaylist] {
        var jsonData = data
        if data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b {
            if let ungz = LXSyncCrypto.gunzipData(data), !ungz.isEmpty {
                jsonData = ungz
            }
        }
        return try parse(data: jsonData)
    }

    /// 把解析出的歌单（歌曲已带 source + songmid）直接写入本地，
    /// 不二次匹配，忠实保留 LX 原始音源。返回 (新建歌单数, 歌曲数)
    static func importParsed(_ lists: [ImportPlaylist]) -> (playlists: Int, songs: Int) {
        var songTotal = 0
        for pl in lists {
            let playlist = Playlist(
                name: pl.name,
                source: "local",
                sourceListId: "",
                location: "local",
                songs: pl.songs
            )
            PlaylistStore.shared.add(playlist)
            songTotal += pl.songs.count
        }
        return (lists.count, songTotal)
    }

    /// 把本机歌单编码为 LX 兼容 JSON（结构同「形状 B」，可再导回本 App；
    /// 导入 LX 桌面版为尽力而为，因 LX 各版本导入 schema 略有差异）
    static func encode(playlists: [Playlist]) -> Data {
        var outLists: [[String: Any]] = []
        for pl in playlists {
            var items: [[String: Any]] = []
            for s in pl.songs {
                var meta: [String: Any] = [:]
                if !s.songmid.isEmpty { meta["songId"] = s.songmid }
                if let aid = s.albumId, !aid.isEmpty { meta["albumId"] = aid }
                if let pic = s.imgUrl, !pic.isEmpty { meta["picUrl"] = pic }
                if let an = s.albumName, !an.isEmpty { meta["albumName"] = an }

                var item: [String: Any] = [
                    "id": s.songmid,
                    "name": s.name,
                    "singer": s.singer,
                    "source": s.source,
                    "interval": formatInterval(s.interval),
                ]
                if let pic = s.imgUrl, !pic.isEmpty { item["pic"] = pic }
                item["meta"] = meta
                items.append(item)
            }
            var outList: [String: Any] = ["list": items]
            outList["name"] = pl.name
            outList["source"] = pl.source
            outLists.append(outList)
        }
        let root: [String: Any] = ["playlists": outLists]
        return (try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)) ?? Data()
    }

    // MARK: - 内部

    private static func songsFromArray(_ arr: [Any]?) -> [Song] {
        guard let arr = arr else { return [] }
        var out: [Song] = []
        var seen = Set<String>()
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            guard let s = song(from: d) else { continue }
            if seen.insert(s.id).inserted { out.append(s) }
        }
        return out
    }

    /// 单首：归一化 LX 字段（把 meta 里的 picUrl/albumId/songId 提到顶层便于 Song 解析）→ Song
    private static func song(from item: [String: Any]) -> Song? {
        var d = item
        if let meta = item["meta"] as? [String: Any] {
            if d["pic"] == nil, let pic = meta["picUrl"] as? String, !pic.isEmpty { d["pic"] = pic }
            if d["albumId"] == nil, let aid = meta["albumId"] { d["albumId"] = aid }
            if d["hash"] == nil, let sid = meta["songId"] { d["hash"] = "\(sid)" }
        }
        let source = nonEmpty(item["source"]) ?? "wy"
        return Song.init(from: d, source: source)
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    private static func formatInterval(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
