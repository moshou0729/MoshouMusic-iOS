import Foundation

/// 歌单搜索结果（原生 HTTP 实现，绕过不支持「歌单搜索」action 的音源脚本）
struct SearchedPlaylist {
    let name: String
    let source: String          // wy / tx / kg
    let sourceListId: String    // 用于拉取整张歌单的 id
    let trackCount: Int
    let creator: String
    let coverUrl: String?
}

/// 各音源「歌单搜索」原生实现
///
/// 音源脚本（tx/mg/wy/kg.js）只实现了 musicSearch / musicUrl / lyric / pic / musicBoard，
/// 没有歌单搜索 action，因此原先「歌单」模式会退化为返回单曲。这里直接调各平台公开搜索
/// 接口返回「歌单名字 + id」，点击后交给 PlaylistImporter 拉取整张并播放。
final class PlaylistSearchService {

    static let shared = PlaylistSearchService()

    /// 支持的歌单搜索音源
    static let supportedSources = ["wy", "tx", "kg"]

    func search(
        keyword: String,
        source: String,
        page: Int = 1,
        completion: @escaping (Result<[SearchedPlaylist], Error>) -> Void
    ) {
        let kw = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 包一层：拿到结果后做客户端相关性过滤。
        // QQ 公开 API 经常返回与搜索词无关的歌单（用户报告「搜的和出来的不匹配」就是这个原因）；
        // 网易云/酷狗偶有漏网。一并过滤能显著提升「点了像搜的那个」的命中率。
        let wrapped: (Result<[SearchedPlaylist], Error>) -> Void = { res in
            switch res {
            case .failure:
                completion(.failure)
            case .success(let lists):
                completion(.success(self.filterRelevant(lists, keyword: keyword)))
            }
        }
        switch source {
        case "wy": searchNetease(kw: kw, page: page, completion: wrapped)
        case "tx": searchQQ(kw: kw, page: page, completion: wrapped)
        case "kg": searchKugou(kw: kw, page: page, completion: wrapped)
        default:
            // 其余音源（kw / mg / 自定义脚本）脚本未实现歌单搜索，返回空（不算错误）
            completion(.success([]))
        }
    }

    // MARK: - 相关性过滤

    /// 客户端相关性过滤：保留 name 与搜索词「有关」的歌单
    private func filterRelevant(_ lists: [SearchedPlaylist], keyword: String) -> [SearchedPlaylist] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lists }
        return lists.filter { Self.isNameRelevant($0.name, keyword: trimmed) }
    }

    /// 名称与搜索词相关：包含整个搜索词，或至少有一个搜索词字符出现在名称中
    /// （避免误杀语义相关但无整词匹配的歌单，如搜「周杰伦」时保留「jay 精选」）
    private static func isNameRelevant(_ name: String, keyword: String) -> Bool {
        if name.contains(keyword) { return true }
        for ch in keyword where name.contains(ch) { return true }
        return false
    }

    // MARK: - 网易云

    private func searchNetease(kw: String, page: Int, completion: @escaping (Result<[SearchedPlaylist], Error>) -> Void) {
        let offset = (page - 1) * 30
        let url = "https://music.163.com/api/cloudsearch/pc"
        let body = "s=\(kw)&type=1000&limit=30&offset=\(offset)"
        let headers = [
            "Referer": "https://music.163.com/",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        NetworkManager.shared.request(url: url, method: "POST", headers: headers, body: body) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let resp):
                    guard let data = resp.rawData,
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let res = dict["result"] as? [String: Any],
                          let lists = res["playlists"] as? [[String: Any]] else {
                        completion(.success([])); return
                    }
                    completion(.success(lists.compactMap { Self.parseNetease($0) }))
                }
            }
        }
    }

    private static func parseNetease(_ d: [String: Any]) -> SearchedPlaylist? {
        let id: String
        if let i = d["id"] as? Int { id = "\(i)" }
        else if let s = d["id"] as? String, !s.isEmpty { id = s }
        else { return nil }
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        let creator = (d["creator"] as? [String: Any])?["nickname"] as? String ?? ""
        let trackCount = d["trackCount"] as? Int ?? 0
        let cover = d["coverImgUrl"] as? String
        return SearchedPlaylist(name: name, source: "wy", sourceListId: id,
                                trackCount: trackCount, creator: creator, coverUrl: cover)
    }

    // MARK: - QQ 音乐

    private func searchQQ(kw: String, page: Int, completion: @escaping (Result<[SearchedPlaylist], Error>) -> Void) {
        let dataParam: [String: Any] = [
            "req": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "remoteplace": "txt.mqq.all",
                    "search_type": 3,
                    "query": kw,
                    "page_num": page,
                    "num_per_page": 30
                ]
            ]
        ]
        guard let dataJSON = try? JSONSerialization.data(withJSONObject: dataParam),
              let dataStr = String(data: dataJSON, encoding: .utf8)?
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(NSError(domain: "PlaylistSearch", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "参数编码失败"])))
            return
        }
        let url = "https://u.y.qq.com/cgi-bin/musicu.fcg?-=pl&g_tk=5381&format=json&inCharset=utf8" +
                  "&outCharset=utf-8&notice=0&platform=h5&needNewCode=1&data=\(dataStr)"
        let headers = ["Referer": "https://y.qq.com/"]
        NetworkManager.shared.request(url: url, headers: headers) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let resp):
                    guard let data = resp.rawData,
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let req = dict["req"] as? [String: Any],
                          let reqData = req["data"] as? [String: Any],
                          let body = reqData["body"] as? [String: Any],
                          let songlist = body["songlist"] as? [String: Any],
                          let lists = songlist["list"] as? [[String: Any]] else {
                        completion(.success([])); return
                    }
                    completion(.success(lists.compactMap { Self.parseQQ($0) }))
                }
            }
        }
    }

    private static func parseQQ(_ d: [String: Any]) -> SearchedPlaylist? {
        // QQ 搜索接口有时把歌单名偶发 hex(UTF-8) 化（用户看到「E4BA94E69C88E5A4A9」=「五月天」）。
        //
        // 之前是「整串全是 hex」才替换——但实际很多情况是「部分字符 hex + 部分正常字符」混杂，
        // 整串策略几乎不命中。这里换成「局部 hex 段探测」：
        // 找出所有长度 ≥ 6 的连续 hex 段，逐段尝试 hex→UTF-8 解码，能解出可读
        // 文本（无控制字符、无 Unicode 替换字符）就替换。
        func tryHexDecode(_ s: String) -> String {
            guard !s.isEmpty else { return s }
            // 用 NSRegularExpression 而不是 Swift regex，方便在 iOS 14 上跑
            guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{6,}") else { return s }
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return s }
            var result = s
            // 从后往前替换，避免 range 错位
            for m in matches.reversed() {
                let r = m.range
                guard r.location + r.length <= ns.length else { continue }
                let raw = ns.substring(with: r)
                // 只对偶数长度尝试解码（hex 字节对齐）
                guard raw.count % 2 == 0,
                      raw.count >= 4 else { continue }
                var bytes: [UInt8] = []
                bytes.reserveCapacity(raw.count / 2)
                var i = raw.startIndex
                var bad = false
                while i < raw.endIndex {
                    let j = raw.index(i, offsetBy: 2)
                    if let b = UInt8(raw[i..<j], radix: 16) {
                        bytes.append(b); i = j
                    } else { bad = true; break }
                }
                if bad { continue }
                guard let decoded = String(bytes: bytes, encoding: .utf8), !decoded.isEmpty else { continue }
                // 必须是「像文本」：不允许 Unicode 替换字符 U+FFFD、控制字符、过长
                if decoded.contains("\u{FFFD}") { continue }
                if decoded.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) { continue }
                if decoded.count < 2 || decoded.count > 200 { continue }
                // 含中文字符（CJK） 或常见拉丁字母提高命中率
                if decoded.unicodeScalars.allSatisfy({ ($0.value < 0x80) && !($0.value >= 0x41 && $0.value <= 0x7A) && !($0.value >= 0x61 && $0.value <= 0x7A) }) {
                    // 全是数字 / 符号——不太像歌单名，跳过
                    continue
                }
                let startIdx = result.index(result.startIndex, offsetBy: r.location)
                let endIdx = result.index(startIdx, offsetBy: r.length)
                result.replaceSubrange(startIdx..<endIdx, with: decoded)
            }
            return result
        }
        // QQ 偶发「双重 hex」：对 hex 串再 hex 编码一次，单趟解码后仍是一长串字符
        // （用户看到的就是这种）。循环解码直到结果稳定（最多 3 层）。
        func tryHexDecodeRepeated(_ s: String) -> String {
            var cur = s
            for _ in 0..<3 {
                let next = tryHexDecode(cur)
                if next == cur { break }
                cur = next
            }
            return cur
        }
        // 名称：兼容 dissname / name / title 三个常见字段名
        let rawName: String
        if let s = d["dissname"] as? String, !s.isEmpty { rawName = s }
        else if let s = d["name"] as? String, !s.isEmpty { rawName = s }
        else if let s = d["title"] as? String, !s.isEmpty { rawName = s }
        else { return nil }
        let name = tryHexDecodeRepeated(rawName)
        guard !name.isEmpty else { return nil }
        // ID：dissid 偶发是 hex（decoded 之后是乱码），只接受纯十进制数字串；其它情况
        // 也尝试 hex-decode 拿到能用的整数字符串。
        let rawId: String
        if let s = d["dissid"] as? String, !s.isEmpty { rawId = s }
        else if let i = d["dissid"] as? Int { rawId = "\(i)" }
        else { return nil }
        // ⚠️ dissid 绝不能做 hex 解码：QQ 的歌单 ID 本身就可能含字母/前导零，
        // 一旦被当成 hex 解成别的值，拉取到的就是另一张歌单
        // （表现为「点开的内容跟搜索结果不是同一个」）。
        let id = rawId
        guard !id.isEmpty else { return nil }
        let creator = (d["creator"] as? [String: Any])?["name"] as? String ?? ""
        let trackCount = d["song_count"] as? Int
            ?? d["songcount"] as? Int
            ?? d["total_song_count"] as? Int
            ?? 0
        let cover = d["imgurl"] as? String
        return SearchedPlaylist(name: name, source: "tx", sourceListId: id,
                                trackCount: trackCount, creator: creator, coverUrl: cover)
    }

    // MARK: - 酷狗

    private func searchKugou(kw: String, page: Int, completion: @escaping (Result<[SearchedPlaylist], Error>) -> Void) {
        let url = "https://mobiles.kugou.com/api/v3/search/special?keyword=\(kw)&page=\(page)&pagesize=30&ver=1&showtype=1"
        let headers = ["Referer": "https://m.kugou.com/"]
        NetworkManager.shared.request(url: url, headers: headers) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let resp):
                    guard let data = resp.rawData,
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let d = dict["data"] as? [String: Any],
                          let lists = d["info"] as? [[String: Any]] else {
                        completion(.success([])); return
                    }
                    completion(.success(lists.compactMap { Self.parseKugou($0) }))
                }
            }
        }
    }

    private static func parseKugou(_ d: [String: Any]) -> SearchedPlaylist? {
        let id: String
        if let i = d["specialid"] as? Int { id = "\(i)" }
        else if let s = d["specialid"] as? String, !s.isEmpty { id = s }
        else { return nil }
        guard let name = d["specialname"] as? String, !name.isEmpty else { return nil }
        let creator = d["nickname"] as? String ?? ""
        let trackCount = d["songcount"] as? Int ?? 0
        var cover = d["imgurl"] as? String
        // 酷狗封面含 {size} 占位符，替换为实际尺寸
        if let c = cover, c.contains("{size}") {
            cover = c.replacingOccurrences(of: "{size}", with: "150")
        }
        return SearchedPlaylist(name: name, source: "kg", sourceListId: id,
                                trackCount: trackCount, creator: creator, coverUrl: cover)
    }
}
