import Foundation

/// 歌曲模型
struct Song: Codable, Equatable {
    let id: String          // 唯一标识: "source_songmid"
    let name: String        // 歌曲名
    let singer: String      // 歌手
    let source: String      // 来源: kw/tx/mg/wy/kg
    let songmid: String     // 源平台歌曲ID
    let albumName: String?  // 专辑名
    let albumId: String?    // 专辑ID
    let imgUrl: String?     // 封面URL
    let quality: String?    // 音质
    let interval: Int       // 时长(秒)
    let meta: [String: String]? // 额外元数据

    /// 「原唱」综合评分 — 同时考虑正向信号（原唱/原版/原曲/Original）和负向信号
    /// （翻唱/cover/live/伴奏/remix），让真正"原版"的曲目排到最前
    ///
    /// 注意：音源脚本通常不在数据中标 isOriginal，只能依赖歌名启发式判断。
    /// 仅有「原唱/原版/原曲/Original」全靠关键词，且经常不准。
    /// 增加负向信号后能更稳定把「live / 翻唱 / 伴奏版」压到后面。
    var originalScore: Int {
        let lower = name.lowercased()
        var score = 0

        // 正向：与原唱相关
        if lower.contains("原唱") || lower.contains("原版") || lower.contains("原曲") ||
           lower.contains("original") || lower.contains("original mix") {
            score += 10
        }
        // 负向：明显不是原唱
        if lower.contains("翻唱") || lower.contains("翻自") || lower.contains("翻奏") ||
           lower.contains("cover") || lower.contains("covered by") {
            score -= 10
        }
        if lower.contains("live") || lower.contains("现场") || lower.contains("concert") ||
           lower.contains("演唱会") {
            score -= 5
        }
        if lower.contains("伴奏") || lower.contains("instrumental") || lower.contains("纯音乐") ||
           lower.contains("backing track") || lower.contains("卡拉ok") || lower.contains("k歌") {
            score -= 8
        }
        if lower.contains("remix") { score -= 3 }
        if lower.contains("remaster") || lower.contains("修复") { score -= 1 }  // 老唱片修复版一般较原版
        if lower.contains("dj版") || lower.contains("dj版") || lower.contains("车载") { score -= 4 }

        return score
    }

    /// 音质排序权重（越高越优先）：无损/FLAC > SQ/320 > 128 > 未知
    var qualityRank: Int {
        let q = (quality ?? "").lowercased()
        if q.contains("flac") || q.contains("无损") { return 3 }
        if q.contains("sq") || q.contains("320") { return 2 }
        if q.contains("128") { return 1 }
        return 0
    }

    // 生成唯一 ID
    static func makeId(source: String, songmid: String) -> String {
        return "\(source)_\(songmid)"
    }

    // Equatable
    static func == (lhs: Song, rhs: Song) -> Bool {
        return lhs.id == rhs.id
    }
}

/// 搜索结果项 (从脚本返回的原始字典转换为 Song)
extension Song {

    /// 宽松取字符串 — JS 返回的数字/布尔经 JSValue 转换后是 NSNumber，
    /// 直接 `as? String` 会失败并导致整条记录被丢弃（曾表现为「某音源没有内容」）
    private static func str(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        if value is NSNull { return nil }
        let described = String(describing: value)
        return described.isEmpty ? nil : described
    }

    private static func intVal(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String {
            // 兼容 "3:35" / "215" / "215.0"
            if s.contains(":") {
                let parts = s.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { return parts[0] * 60 + parts[1] }
                if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            }
            return Int(Double(s) ?? 0)
        }
        return 0
    }

    init?(from dict: [String: Any], source: String) {
        // songmid 兼容多种命名，且允许数字类型
        let midCandidates = ["songmid", "id", "hash", "songId", "rid", "copyrightId"]
        var songmid: String?
        for key in midCandidates {
            if let v = Song.str(dict[key]) { songmid = v; break }
        }

        guard let mid = songmid, let name = Song.str(dict["name"]) ?? Song.str(dict["songName"]) else {
            return nil
        }

        let singer = Song.str(dict["singer"]) ?? Song.str(dict["artist"]) ?? "未知歌手"
        let albumName = Song.str(dict["albumName"]) ?? Song.str(dict["album"])
        let albumId = Song.str(dict["albumId"])
        let imgUrl = Song.str(dict["img"]) ?? Song.str(dict["pic"]) ?? Song.str(dict["cover"])
        let quality = Song.str(dict["quality"])
        let interval = Song.intVal(dict["interval"] ?? dict["duration"])

        // meta 宽松转换：承载平台特有字段（酷狗 hash、咪咕 contentId/copyrightId 等）
        var meta: [String: String] = [:]
        if let raw = dict["meta"] as? [String: Any] {
            for (k, v) in raw {
                if let s = Song.str(v) { meta[k] = s }
            }
        }

        self.init(
            id: Song.makeId(source: source, songmid: mid),
            name: name,
            singer: singer,
            source: source,
            songmid: mid,
            albumName: albumName,
            albumId: albumId,
            imgUrl: imgUrl,
            quality: quality,
            interval: interval,
            meta: meta.isEmpty ? nil : meta
        )
    }
}

/// 歌单模型
struct Playlist: Codable {
    var id: String
    var name: String
    var source: String        // 来源平台
    var sourceListId: String  // 源列表ID
    var location: String      // local / online
    var songs: [Song]
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, source: String = "local",
         sourceListId: String = "", location: String = "local", songs: [Song] = []) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceListId = sourceListId
        self.location = location
        self.songs = songs
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// 播放模式
enum PlayMode: Int, CaseIterable {
    case listRepeat = 0    // 列表循环
    case singleRepeat = 1  // 单曲循环
    case listOrder = 2     // 顺序播放
    case random = 3        // 随机播放

    var iconName: String {
        switch self {
        case .listRepeat: return "repeat"
        case .singleRepeat: return "repeat.1"
        case .listOrder: return "arrow.right"
        case .random: return "shuffle"
        }
    }

    var displayName: String {
        switch self {
        case .listRepeat: return "列表循环"
        case .singleRepeat: return "单曲循环"
        case .listOrder: return "顺序播放"
        case .random: return "随机播放"
        }
    }
}
