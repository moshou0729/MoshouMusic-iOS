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
    init?(from dict: [String: Any], source: String) {
        guard let songmid = dict["songmid"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }

        let singer = dict["singer"] as? String ?? "未知歌手"
        let albumName = dict["albumName"] as? String
        let albumId = dict["albumId"] as? String
        let imgUrl = dict["img"] as? String
        let quality = dict["quality"] as? String
        let interval = (dict["interval"] as? Int) ?? 0
        let meta = dict["meta"] as? [String: String]

        self.init(
            id: Song.makeId(source: source, songmid: songmid),
            name: name,
            singer: singer,
            source: source,
            songmid: songmid,
            albumName: albumName,
            albumId: albumId,
            imgUrl: imgUrl,
            quality: quality,
            interval: interval,
            meta: meta
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
