import Foundation
import UIKit

/// v1.0.141：歌曲评论模型
struct SongComment {
    let nickname: String
    let avatarURL: URL?
    let content: String
    let likes: Int
    let timeText: String
    let isHot: Bool
}

/// v1.0.153：一次评论请求的完整结果 —— 除了评论本身，还要把「这些评论到底来自哪里」说清楚。
///
/// 之所以需要它：本 App 的播放音源可能是 QQ音乐 / 酷狗 / 酷我 / 咪咕，但评论一律取自网易云。
/// 如果只把评论丢给 UI，用户会以为「我在酷狗播，怎么显示的是网易云的评论」是 bug；
/// 带上来源与匹配信息后，页面就能明确写清「当前歌曲来自 X，评论匹配自网易云《Y》- Z」。
struct CommentFeed {
    /// 评论数据来源显示名（当前固定为「网易云」）
    let sourceName: String
    /// 当前播放音源显示名（如「QQ音乐」）
    let playSourceName: String
    /// 是否直接用当前播放音源自家的评论（false = 同名匹配到别的平台）
    let isNativeSource: Bool
    /// 实际取到评论的歌曲名 / 歌手（同名匹配时可能与当前播放的歌不同）
    let matchedName: String
    let matchedSinger: String
    let comments: [SongComment]
    let total: Int
}

/// v1.0.141：歌曲评论服务。
///
/// **评论来源的现状（2026-09-11 实测，别再翻烧饼）**：
/// 只有网易云的评论区可以直接匿名读取；其余平台的评论接口都已收回登录态之后：
/// - QQ音乐 musicu `music.globalComment.CommentRead` → `code: 40000`（需登录 cookie）；
///   旧的 `c.y.qq.com/base/fcgi-bin/fcg_global_comment_hot` 已下线（404）。
/// - 酷狗 `mobiles.kugou.com/api/v1/comment/getcomments` → 404；`m.kugou.com/app/i/comment.php`
///   → "No Action Found"；`www.kugou.com/yy/index.php?r=comment/getcomments` → Access Deny。
/// - 酷我 `comment.kuwo.cn/com.s` → `code: 600 评论失败`。
/// - 咪咕 `music.migu.cn/v3/api/comment/list` → 返回 HTML 页面（接口已改）。
///
/// 所以无论当前播放音源是什么，评论统一走**网易云同名匹配**，并在 UI 上把来源与匹配结果
/// 明确标出（见 CommentFeed）。匹配不上时宁可报错也不乱配（评论错歌比没有评论更糟）。
final class CommentService {

    static let shared = CommentService()

    /// 网易云评论来源显示名
    static let netEaseDisplayName = "网易云"

    /// 网易云匹配结果（wy id + 匹配到的歌名歌手，用于在 UI 上标注「匹配到了哪一首」）
    struct WyMatch {
        let id: String
        let name: String
        let singer: String
    }

    /// 匹配缓存（key = "source_songmid"）
    private var wyMatchCache: [String: WyMatch] = [:]
    /// 头像图片内存缓存
    private let imageCache = NSCache<NSURL, UIImage>()

    // MARK: - 对外

    /// 取评论（offset 分页：0 起步，调用方传已取到的条数）
    func fetchComments(for song: Song, offset: Int,
                       playSourceName: String,
                       completion: @escaping (Result<CommentFeed, Error>) -> Void) {
        resolveWyMatch(for: song) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let match):
                self.fetchNetEaseComments(wyId: match.id, offset: offset) { inner in
                    switch inner {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let payload):
                        let feed = CommentFeed(
                            sourceName: CommentService.netEaseDisplayName,
                            playSourceName: playSourceName,
                            isNativeSource: song.source == "wy",
                            matchedName: match.name,
                            matchedSinger: match.singer,
                            comments: payload.comments,
                            total: payload.total)
                        completion(.success(feed))
                    }
                }
            }
        }
    }

    /// 异步加载头像（内存缓存）
    func loadImage(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let hit = imageCache.object(forKey: url as NSURL) {
            completion(hit)
            return
        }
        NetworkManager.shared.request(url: url.absoluteString, timeout: 12, isBinary: true) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    guard resp.statusCode == 200, let raw = resp.rawData, let img = UIImage(data: raw) else {
                        completion(nil)
                        return
                    }
                    self?.imageCache.setObject(img, forKey: url as NSURL)
                    completion(img)
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    // MARK: - 网易云歌曲匹配

    private func resolveWyMatch(for song: Song, completion: @escaping (Result<WyMatch, Error>) -> Void) {
        if song.source == "wy" {
            completion(.success(WyMatch(id: song.songmid, name: song.name, singer: song.singer)))
            return
        }
        let cacheKey = song.source + "_" + song.songmid
        if let cached = wyMatchCache[cacheKey] {
            completion(.success(cached))
            return
        }
        let keyword = Self.cleanKeyword("\(song.name) \(song.singer)")
        // 先走内置 wy 源，失败再走 LX 兼容层
        ScriptEngine.shared.search(keyword: keyword, source: "wy") { [weak self] result in
            switch result {
            case .success(let list):
                if let matched = self?.bestMatch(from: list, song: song) {
                    let m = WyMatch(id: matched.songmid, name: matched.name, singer: matched.singer)
                    self?.wyMatchCache[cacheKey] = m
                    completion(.success(m))
                    return
                }
                self?.fallbackLXSearch(keyword: keyword, song: song, cacheKey: cacheKey, completion: completion)
            case .failure:
                self?.fallbackLXSearch(keyword: keyword, song: song, cacheKey: cacheKey, completion: completion)
            }
        }
    }

    private func fallbackLXSearch(keyword: String, song: Song, cacheKey: String,
                                  completion: @escaping (Result<WyMatch, Error>) -> Void) {
        LXCompatEngine.shared.search(keyword: keyword, platform: "wy") { [weak self] result in
            switch result {
            case .success(let list):
                if let matched = self?.bestMatch(from: list, song: song) {
                    let m = WyMatch(id: matched.songmid, name: matched.name, singer: matched.singer)
                    self?.wyMatchCache[cacheKey] = m
                    completion(.success(m))
                } else {
                    completion(.failure(NSError(
                        domain: "CommentService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "网易云里没找到《\(song.name)》的对应版本，暂无评论可看"])))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 歌名+歌手匹配打分：歌名一致 +10（互含 +5），歌手 token 交集每个 +2；
    /// 低于阈值视为没匹配上，返回 nil（宁可不显示也不串评论）。
    private func bestMatch(from list: [[String: Any]], song: Song) -> Song? {
        let candidates = list.compactMap { Song(from: $0, source: "wy") }
        guard !candidates.isEmpty else { return nil }
        let wantName = Self.cleanKeyword(song.name).lowercased()
        let wantSingers = Self.singerTokens(song.singer)
        var best: (Song, Int)?
        for c in candidates {
            let cName = Self.cleanKeyword(c.name).lowercased()
            var score = 0
            if cName == wantName {
                score += 10
            } else if !wantName.isEmpty, cName.contains(wantName) || wantName.contains(cName) {
                score += 5
            }
            score += wantSingers.intersection(Self.singerTokens(c.singer)).count * 2
            if score >= 5, score > (best?.1 ?? 0) {
                best = (c, score)
            }
        }
        return best?.0
    }

    private static func singerTokens(_ raw: String) -> Set<String> {
        return Set(Self.cleanKeyword(raw).lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "/,&、 ")).filter { !$0.isEmpty })
    }

    /// 去括号补充内容（Live版/DJ版 等）与首尾空白
    static func cleanKeyword(_ raw: String) -> String {
        var s = raw
        for (open, close) in [("（", "）"), ("(", ")"), ("[", "]"), ("【", "】")] {
            while let r = s.range(of: open), let r2 = s.range(of: close),
                  r.lowerBound < r2.lowerBound, r2.upperBound <= s.endIndex {
                s = s.replacingCharacters(in: r.lowerBound..<r2.upperBound, with: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 网易云评论 API

    private func fetchNetEaseComments(wyId: String, offset: Int,
                                      completion: @escaping (Result<(comments: [SongComment], total: Int), Error>) -> Void) {
        let url = "https://music.163.com/api/v1/resource/comments/R_SO_4_\(wyId)?limit=40&offset=\(offset)"
        NetworkManager.shared.request(
            url: url, method: "GET",
            headers: ["Referer": "https://music.163.com/"],
            timeout: 15
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    guard resp.statusCode == 200,
                          let data = resp.body.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        completion(.failure(NSError(
                            domain: "CommentService", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "评论服务返回异常（HTTP \(resp.statusCode)），稍后再试"])))
                        return
                    }
                    let total = obj["total"] as? Int ?? 0
                    let hot = obj["hotComments"] as? [[String: Any]] ?? []
                    let latest = obj["comments"] as? [[String: Any]] ?? []
                    if hot.isEmpty && latest.isEmpty && total == 0 {
                        completion(.failure(NSError(
                            domain: "CommentService", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "这首歌还没有评论"])))
                        return
                    }
                    var out: [SongComment] = hot.map { Self.parse($0, isHot: true) }
                    out += latest.map { Self.parse($0, isHot: false) }
                    completion(.success((out, total)))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private static func parse(_ d: [String: Any], isHot: Bool) -> SongComment {
        let user = d["user"] as? [String: Any] ?? [:]
        let nickname = user["nickname"] as? String ?? "云村网友"
        let avatar = (user["avatarUrl"] as? String).flatMap(URL.init(string:))
        let content = d["content"] as? String ?? ""
        let likes = d["likedCount"] as? Int ?? 0
        var timeText = ""
        if let ms = d["time"] as? Double, ms > 0 {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            timeText = df.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        return SongComment(nickname: nickname, avatarURL: avatar,
                           content: content, likes: likes, timeText: timeText, isHot: isHot)
    }
}
