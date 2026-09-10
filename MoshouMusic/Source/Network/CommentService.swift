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

/// v1.0.141：歌曲评论服务 —— 统一取网易云评论区（各音源里网易云评论最全）。
/// wy 歌直接用 songmid；其他音源先在 wy 搜索同名歌拿到 wy id 再取评论，
/// 找不到匹配时明确报错，不乱配（评论错歌比没有评论更糟）。
final class CommentService {

    static let shared = CommentService()

    /// wy id 解析缓存（key = "source_songmid"）
    private var wyIdCache: [String: String] = [:]
    /// 头像图片内存缓存
    private let imageCache = NSCache<NSURL, UIImage>()

    // MARK: - 对外

    /// 取评论（offset 分页：0 起步，调用方传已取到的条数）
    func fetchComments(for song: Song, offset: Int,
                       completion: @escaping (Result<(comments: [SongComment], total: Int), Error>) -> Void) {
        resolveWySongId(for: song) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let wyId):
                self.fetchNetEaseComments(wyId: wyId, offset: offset, completion: completion)
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

    // MARK: - wy id 解析

    private func resolveWySongId(for song: Song, completion: @escaping (Result<String, Error>) -> Void) {
        if song.source == "wy" {
            completion(.success(song.songmid))
            return
        }
        let cacheKey = song.source + "_" + song.songmid
        if let cached = wyIdCache[cacheKey] {
            completion(.success(cached))
            return
        }
        let keyword = Self.cleanKeyword("\(song.name) \(song.singer)")
        // 先走内置 wy 源，失败再走 LX 兼容层
        ScriptEngine.shared.search(keyword: keyword, source: "wy") { [weak self] result in
            switch result {
            case .success(let list):
                if let id = self?.bestMatchId(from: list, song: song) {
                    self?.wyIdCache[cacheKey] = id
                    completion(.success(id))
                    return
                }
                self?.fallbackLXSearch(keyword: keyword, song: song, cacheKey: cacheKey, completion: completion)
            case .failure:
                self?.fallbackLXSearch(keyword: keyword, song: song, cacheKey: cacheKey, completion: completion)
            }
        }
    }

    private func fallbackLXSearch(keyword: String, song: Song, cacheKey: String,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        LXCompatEngine.shared.search(keyword: keyword, platform: "wy") { [weak self] result in
            switch result {
            case .success(let list):
                if let id = self?.bestMatchId(from: list, song: song) {
                    self?.wyIdCache[cacheKey] = id
                    completion(.success(id))
                } else {
                    completion(.failure(NSError(
                        domain: "CommentService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "网易云里没找到这首歌的对应版本，暂无评论可看"])))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 歌名+歌手匹配打分：歌名一致 +10（互含 +5），歌手 token 交集每个 +2；
    /// 低于阈值视为没匹配上，返回 nil（宁可不显示也不串评论）。
    private func bestMatchId(from list: [[String: Any]], song: Song) -> String? {
        let candidates = list.compactMap { Song(from: $0, source: "wy") }
        guard !candidates.isEmpty else { return nil }
        let wantName = Self.cleanKeyword(song.name).lowercased()
        let wantSingers = Self.singerTokens(song.singer)
        var best: (String, Int)?
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
                best = (c.songmid, score)
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
