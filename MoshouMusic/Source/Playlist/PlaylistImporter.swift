import Foundation

/// 歌单分享链接导入
///
/// 支持平台：
/// - 网易云音乐（playlist / album / song）：走公开 API（music.163.com/api/...），无需登录，最稳
/// - QQ 音乐（playlist / song）：走 c.y.qq.com 的 fcg 接口
/// - 酷狗音乐（song / playlist）：走 getdata / special 接口（best-effort，部分分享链接需服务端签名会失败）
///
/// 流程：解析链接（含短链重定向）→ 拉取曲目列表 → 逐首在本机 5 个音源 + 7 个社区源中按「歌名+歌手」匹配
/// → 命中的 Song 写入本地歌单 → 产出导入报告（成功 / 跳过）。
final class PlaylistImporter {

    static let shared = PlaylistImporter()

    // MARK: - 对外类型

    struct Track {
        let name: String
        let artist: String
        let album: String?
    }

    struct Progress {
        let platform: String
        let stage: String
        let current: Int
        let total: Int
        let matched: Int
    }

    struct ImportResult {
        let playlistName: String
        let platform: String
        let total: Int
        let matched: Int
        let skipped: [Track]
        let playlist: Playlist
    }

    enum ImportError: Error, LocalizedError {
        case unsupportedLink(String)
        case parseFailed(String)
        case empty
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedLink(let s): return "无法识别的分享链接：\(s)"
            case .parseFailed(let s): return s
            case .empty: return "该链接没有解析到任何歌曲"
            case .network(let e): return "网络错误：\(e.localizedDescription)"
            }
        }
    }

    // MARK: - 内部类型

    private enum Platform { case netease, qq, kugou }
    private enum LinkType { case playlist, album, song }
    private struct ParsedLink {
        let platform: Platform
        let platformKey: String
        let platformName: String
        let type: LinkType
        let id: String
    }

    // MARK: - 入口

    func importFromLink(
        link: String,
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Swift.Result<ImportResult, Error>) -> Void
    ) {
        // 保证进度/结果一定在主线程回调，方便 UI 直接更新
        let safeProgress: (Progress) -> Void = { p in DispatchQueue.main.async { progress(p) } }
        let safeComplete: (Swift.Result<ImportResult, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }

        guard let cleaned = Self.extractURL(link) else {
            safeComplete(.failure(ImportError.unsupportedLink(link)))
            return
        }

        safeProgress(Progress(platform: "?", stage: "正在解析链接…", current: 0, total: 0, matched: 0))

        // 先发一次请求以跟随重定向（网易云短链 163cn.tv → y.music.163.com/m/playlist?id=...）
        NetworkManager.shared.request(url: cleaned, followRedirect: true) { [weak self] result in
            guard let self = self else { return }

            var finalURL = cleaned
            if case .success(let resp) = result, let fu = resp.finalURL, !fu.isEmpty {
                finalURL = fu
            }

            guard let parsed = self.parseURL(finalURL) ?? self.parseURL(cleaned) else {
                safeComplete(.failure(ImportError.unsupportedLink(link)))
                return
            }

            self.fetchTracks(parsed, progress: safeProgress) { fetchResult in
                switch fetchResult {
                case .failure(let e):
                    safeComplete(.failure(e))
                case .success(let (name, tracks)):
                    guard !tracks.isEmpty else {
                        safeComplete(.failure(ImportError.empty))
                        return
                    }
                    DispatchQueue.main.async {
                        self.buildPlaylist(
                            name: name,
                            platformKey: parsed.platformKey,
                            platformName: parsed.platformName,
                            listId: parsed.id,
                            tracks: tracks,
                            progress: safeProgress,
                            completion: safeComplete
                        )
                    }
                }
            }
        }
    }

    // MARK: - 链接解析

    /// 从粘贴文本里抠出第一个看起来像链接的片段（兼容 "https://... (@网易云音乐)" 这种带尾巴的）
    private static func extractURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "https?://[^\\s]+", options: .regularExpression) {
            var hit = String(trimmed[range])
            // 去掉结尾常见的标点 / 半角全角括号
            while let last = hit.last, ")。，,.)]};；".contains(last) {
                hit.removeLast()
            }
            return hit
        }
        if trimmed.contains("163cn.tv") || trimmed.contains("kugou.com") ||
           trimmed.contains("qq.com") || trimmed.contains("163.com") {
            return trimmed
        }
        return nil
    }

    private func parseURL(_ urlString: String) -> ParsedLink? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = (components.host ?? "").lowercased()
        let path = components.path.lowercased()
        let queryId = components.queryItems?
            .first(where: { ["id", "disstid", "hash", "specialid", "songmid"].contains($0.name.lowercased()) })?
            .value ?? ""

        guard !queryId.isEmpty else { return nil }

        if host.contains("kugou") {
            let type: LinkType = (path.contains("special") || path.contains("playlist") || path.contains("album")) ? .playlist : .song
            return ParsedLink(platform: .kugou, platformKey: "kg", platformName: "酷狗", type: type, id: queryId)
        } else if host.contains("163") || host.contains("music.163") || host.contains("163cn") {
            let type: LinkType = path.contains("album") ? .album : (path.contains("playlist") ? .playlist : .song)
            return ParsedLink(platform: .netease, platformKey: "wy", platformName: "网易云", type: type, id: queryId)
        } else if host.contains("qq.com") {
            let type: LinkType = (path.contains("song") || components.queryItems?.contains(where: { $0.name.lowercased() == "songmid" }) == true) ? .song : .playlist
            return ParsedLink(platform: .qq, platformKey: "tx", platformName: "QQ音乐", type: type, id: queryId)
        }
        return nil
    }

    // MARK: - 拉取曲目

    private func fetchTracks(
        _ parsed: ParsedLink,
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        switch (parsed.platform, parsed.type) {
        case (.netease, .playlist):
            fetchNeteasePlaylist(id: parsed.id, completion: completion)
        case (.netease, .album):
            fetchNeteaseSongs(url: "https://music.163.com/api/v1/album?id=\(parsed.id)",
                              nameKey: nil, completion: completion)
        case (.netease, .song):
            let encodedIds = "[\(parsed.id)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            fetchNeteaseSongs(url: "https://music.163.com/api/song/detail/?id=\(parsed.id)&ids=\(encodedIds)",
                              nameKey: nil, completion: completion)
        case (.qq, .playlist):
            fetchQQPlaylist(id: parsed.id, completion: completion)
        case (.qq, .song):
            fetchQQSong(songmid: parsed.id, completion: completion)
        case (.kugou, .song):
            fetchKugouSong(hash: parsed.id, completion: completion)
        case (.kugou, .playlist):
            fetchKugouPlaylist(specialid: parsed.id, completion: completion)
        default:
            completion(.failure(ImportError.parseFailed("暂不支持该类型的分享链接")))
        }
    }

    // MARK: - 网易云

    private func fetchNeteasePlaylist(
        id: String,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        let url = "https://music.163.com/api/v6/playlist/detail?id=\(id)"
        fetchJSON(url: url, headers: ["Referer": "https://music.163.com/"]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                completion(.failure(ImportError.network(e)))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let pl = dict["playlist"] as? [String: Any] else {
                    completion(.failure(ImportError.parseFailed("网易云：未能解析歌单数据")))
                    return
                }
                let name = (pl["name"] as? String) ?? "网易云歌单"
                let trackIdsArr = (pl["trackIds"] as? [[String: Any]]) ?? []
                let allIds: [Int] = trackIdsArr.compactMap { $0["id"] as? Int }
                let tracks = self.neTracks(from: dict)

                // 快路径：convenience tracks 已覆盖 trackIds 全部（无需额外请求）
                if !tracks.isEmpty && (allIds.isEmpty || tracks.count >= allIds.count) {
                    completion(.success((name, tracks)))
                    return
                }

                // 慢路径：用 trackIds 批量补全（v6 在大歌单下 tracks 经常被截断到 ~10 首）
                if !allIds.isEmpty {
                    self.batchFetchNeteaseSongs(ids: allIds) { batchResult in
                        switch batchResult {
                        case .failure(let e):
                            // 批量失败但已有部分 convenience tracks → 仍返回它（比整单失败更友好）
                            if !tracks.isEmpty {
                                completion(.success((name, tracks)))
                            } else {
                                completion(.failure(e))
                            }
                        case .success(let fetched):
                            // 优先用批量结果（保证完整），若批量明显更少则用 tracks
                            let merged = fetched.count >= tracks.count ? fetched : tracks
                            completion(.success((name, merged)))
                        }
                    }
                    return
                }

                // 既没 trackIds 也没 tracks
                if tracks.isEmpty {
                    completion(.failure(ImportError.empty))
                } else {
                    completion(.success((name, tracks)))
                }
            }
        }
    }

    /// 按 100 首/批 调 163 v3 song/detail，补全 tracks 列表（修复大歌单只导入 ~10 首）
    /// 接口：`GET /api/v3/song/detail?c=[{"id":1},{"id":2},...]` → `{"songs":[...],"code":200}`
    private func batchFetchNeteaseSongs(
        ids: [Int],
        completion: @escaping (Swift.Result<[Track], Error>) -> Void
    ) {
        let chunkSize = 100
        let chunks: [[Int]] = stride(from: 0, to: ids.count, by: chunkSize).map {
            Array(ids[$0..<min($0 + chunkSize, ids.count)])
        }
        var accumulated: [Track] = []
        var firstError: Error?

        func loadChunk(_ idx: Int) {
            guard idx < chunks.count else {
                if accumulated.isEmpty, let e = firstError {
                    completion(.failure(e))
                } else {
                    completion(.success(accumulated))
                }
                return
            }
            let chunk = chunks[idx]
            // 构造 c=[{"id":1},...] 的 JSON 字符串
            let cArray: [[String: Any]] = chunk.map { ["id": $0] }
            let cJson = (try? JSONSerialization.data(withJSONObject: cArray, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let cParam = cJson.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "[]"
            let url = "https://music.163.com/api/v3/song/detail?c=\(cParam)"
            fetchJSON(url: url, headers: ["Referer": "https://music.163.com/"]) { result in
                switch result {
                case .failure(let e):
                    if firstError == nil { firstError = ImportError.network(e) }
                    // 单批失败不立刻终止：尽力拼完，最后若全空才报错
                    loadChunk(idx + 1)
                case .success(let jsonAny):
                    let chunkTracks = self.neTracks(from: jsonAny)
                    accumulated.append(contentsOf: chunkTracks)
                    loadChunk(idx + 1)
                }
            }
        }
        loadChunk(0)
    }

    private func fetchNeteaseSongs(
        url: String,
        nameKey: String?,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        fetchJSON(url: url, headers: ["Referer": "https://music.163.com/"]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                completion(.failure(ImportError.network(e)))
            case .success(let json):
                let name = (nameKey ?? "网易云歌曲")
                let tracks = self.neTracks(from: json)
                if tracks.isEmpty {
                    completion(.failure(ImportError.empty))
                } else {
                    completion(.success((name, tracks)))
                }
            }
        }
    }

    private func neTracks(from json: Any) -> [Track] {
        guard let dict = json as? [String: Any] else { return [] }
        if let pl = dict["playlist"] as? [String: Any],
           let tracks = pl["tracks"] as? [[String: Any]] {
            return tracks.compactMap { neTrack($0) }
        }
        if let songs = dict["songs"] as? [[String: Any]] {
            return songs.compactMap { neTrack($0) }
        }
        return []
    }

    private func neTrack(_ d: [String: Any]) -> Track? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        let artist = Self.neArtists(d)
        let album = (d["album"] as? [String: Any] ?? d["al"] as? [String: Any])?["name"] as? String
        return Track(name: name, artist: artist, album: album)
    }

    private static func neArtists(_ d: [String: Any]) -> String {
        let arr = (d["artists"] as? [[String: Any]]) ?? (d["ar"] as? [[String: Any]]) ?? []
        let names = arr.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        return names.joined(separator: "/")
    }

    // MARK: - QQ 音乐

    private func fetchQQPlaylist(
        id: String,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        let url = "https://c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg?" +
                  "type=1&json=1&utf8=1&onlysong=0&new_format=1&platform=yqq.json&format=json&id=\(id)"
        fetchJSON(url: url, headers: ["Referer": "https://y.qq.com/"]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                completion(.failure(ImportError.network(e)))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let data = dict["data"] as? [String: Any],
                      let cdlist = data["cdlist"] as? [[String: Any]],
                      let cd = cdlist.first else {
                    completion(.failure(ImportError.parseFailed("QQ音乐：未能解析歌单数据")))
                    return
                }
                let name = (cd["dissname"] as? String) ?? "QQ音乐歌单"
                let songlist = cd["songlist"] as? [[String: Any]] ?? []
                let tracks = songlist.compactMap { Self.qqTrack($0) }
                if tracks.isEmpty {
                    completion(.failure(ImportError.empty))
                } else {
                    completion(.success((name, tracks)))
                }
            }
        }
    }

    private func fetchQQSong(
        songmid: String,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        // QQ 单曲分享：通过 songmid 查歌名（这里只取一首作为单曲歌单）
        let url = "https://c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg?" +
                  "type=1&json=1&utf8=1&onlysong=1&platform=yqq&format=json&id=\(songmid)"
        fetchJSON(url: url, headers: ["Referer": "https://y.qq.com/"]) { result in
            switch result {
            case .failure(let e):
                completion(.failure(ImportError.network(e)))
            case .success(let json):
                guard let dict = json as? [String: Any],
                      let data = dict["data"] as? [String: Any],
                      let cdlist = data["cdlist"] as? [[String: Any]],
                      let cd = cdlist.first else {
                    completion(.failure(ImportError.parseFailed("QQ音乐：未能解析单曲数据")))
                    return
                }
                let songlist = cd["songlist"] as? [[String: Any]] ?? []
                let tracks = songlist.compactMap { Self.qqTrack($0) }
                let name = tracks.first?.name ?? "QQ音乐单曲"
                if tracks.isEmpty {
                    completion(.failure(ImportError.empty))
                } else {
                    completion(.success((name, tracks)))
                }
            }
        }
    }

    private static func qqTrack(_ d: [String: Any]) -> Track? {
        guard let name = d["songname"] as? String, !name.isEmpty else { return nil }
        let singerArr = d["singer"] as? [[String: Any]] ?? []
        let artist = singerArr.compactMap { $0["name"] as? String }.joined(separator: "/")
        let album = d["albumname"] as? String
        return Track(name: name, artist: artist.isEmpty ? "未知歌手" : artist, album: album)
    }

    // MARK: - 酷狗

    private func fetchKugouSong(
        hash: String,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        let url = "https://www.kugou.com/yy/index.php?r=play/getdata&hash=\(hash)&mid=&platid=4"
        fetchJSON(url: url, headers: ["Referer": "https://www.kugou.com/"]) { result in
            switch result {
            case .failure(let e):
                completion(.failure(ImportError.network(e)))
            case .success(let json):
                guard let track = Self.kgTrack(from: json) else {
                    completion(.failure(ImportError.parseFailed(
                        "酷狗该分享链接需要服务端签名，暂无法直接解析。请改用网易云或 QQ 音乐的分享链接。")))
                    return
                }
                completion(.success((track.name, [track])))
            }
        }
    }

    private func fetchKugouPlaylist(
        specialid: String,
        completion: @escaping (Swift.Result<(String, [Track]), Error>) -> Void
    ) {
        // 酷狗 special 接口默认每页约 10 首，需要翻页才能拿到全部曲目（F5 修复：此前只取首页）
        var accumulated: [Track] = []
        var playlistName = "酷狗歌单"
        var page = 1
        let maxPages = 50

        func loadNext() {
            guard page <= maxPages else { finish(); return }
            let url = "https://www.kugou.com/yy/special/single.php?" +
                      "specialid=\(specialid)&json=true&page=\(page)&pagesize=100"
            fetchJSON(url: url, headers: ["Referer": "https://www.kugou.com/"]) { result in
                switch result {
                case .failure(let e):
                    if page == 1 {
                        completion(.failure(ImportError.network(e)))
                    } else {
                        // 后续页失败：返回已收集到的部分（比整单失败更友好）
                        finish()
                    }
                case .success(let json):
                    guard let dict = json as? [String: Any] else {
                        if page == 1 {
                            completion(.failure(ImportError.parseFailed("酷狗歌单解析失败（接口需要签名）。请改用网易云或 QQ 音乐的分享链接。")))
                        } else {
                            finish()
                        }
                        return
                    }
                    if page == 1 {
                        playlistName = (dict["specialname"] as? String) ?? playlistName
                    }
                    let list = (dict["list"] as? [[String: Any]]) ?? []
                    let tracks = list.compactMap { Self.kgPlaylistTrack($0) }
                    accumulated.append(contentsOf: tracks)
                    let total = (dict["total"] as? Int) ?? 0
                    page += 1
                    if list.isEmpty || (total > 0 && accumulated.count >= total) {
                        finish()
                    } else {
                        loadNext()
                    }
                }
            }
        }

        func finish() {
            if accumulated.isEmpty {
                completion(.failure(ImportError.parseFailed(
                    "酷狗歌单解析失败（接口需要签名或该歌单为空）。请改用网易云或 QQ 音乐的分享链接。")))
            } else {
                completion(.success((playlistName, accumulated)))
            }
        }

        loadNext()
    }

    private static func kgTrack(from json: Any) -> Track? {
        guard let dict = json as? [String: Any],
              let data = dict["data"] as? [String: Any] else { return nil }
        // 部分版本字段为 audio_name（"歌名-歌手"），优先用独立的 song_name / singer_name
        let name = (data["song_name"] as? String) ?? (data["audio_name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let singer = (data["singer_name"] as? String) ?? ""
        let album = data["album_name"] as? String
        return Track(name: name, artist: singer.isEmpty ? "未知歌手" : singer, album: album)
    }

    private static func kgPlaylistTrack(_ d: [String: Any]) -> Track? {
        let name = (d["songname"] as? String) ?? (d["filename"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        // filename 常见格式 "歌名-歌手"
        if let fn = d["filename"] as? String, fn.contains("-"),
           let range = fn.range(of: "-") {
            let n = String(fn[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let a = String(fn[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return Track(name: n, artist: a.isEmpty ? "未知歌手" : a, album: d["remark"] as? String)
        }
        let singer = (d["singername"] as? String) ?? ""
        return Track(name: name, artist: singer.isEmpty ? "未知歌手" : singer, album: d["remark"] as? String)
    }

    // MARK: - 通用 JSON 拉取

    private func fetchJSON(
        url: String,
        headers: [String: String],
        completion: @escaping (Swift.Result<Any, Error>) -> Void
    ) {
        NetworkManager.shared.request(url: url, headers: headers) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let resp):
                guard let data = resp.rawData, !data.isEmpty else {
                    completion(.failure(NSError(domain: "PlaylistImporter", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "空响应"])))
                    return
                }
                do {
                    let obj = try JSONSerialization.jsonObject(with: data, options: [])
                    completion(.success(obj))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - 匹配并写入歌单

    private func buildPlaylist(
        name: String,
        platformKey: String,
        platformName: String,
        listId: String,
        tracks: [Track],
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Swift.Result<ImportResult, Error>) -> Void
    ) {
        let playlist = Playlist(
            name: name,
            source: platformKey,
            sourceListId: listId,
            location: "online",
            songs: []
        )
        PlaylistStore.shared.add(playlist)

        var matchedSongs: [Song] = []
        var skipped: [Track] = []
        var idx = 0

        func step() {
            if idx >= tracks.count {
                PlaylistStore.shared.addSongs(matchedSongs, to: playlist.id)
                let result = ImportResult(
                    playlistName: name,
                    platform: platformName,
                    total: tracks.count,
                    matched: matchedSongs.count,
                    skipped: skipped,
                    playlist: playlist
                )
                completion(.success(result))
                return
            }

            let t = tracks[idx]
            idx += 1
            progress(Progress(
                platform: platformName,
                stage: "匹配 \(idx)/\(tracks.count)：\(t.name)",
                current: idx,
                total: tracks.count,
                matched: matchedSongs.count
            ))

            SourceSwitcher.shared.findSong(name: t.name, singer: t.artist) { song in
                if let song = song {
                    matchedSongs.append(song)
                } else {
                    skipped.append(t)
                }
                step()
            }
        }

        step()
    }

    // MARK: - 手动更新在线歌单

    /// 按歌单保存的「平台 + 源列表ID」重新拉取曲目并整体替换本地歌曲（F5）
    /// 仅对 location == "online" 且 sourceListId 非空的歌单有效。
    func updatePlaylist(
        playlistId: String,
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Swift.Result<ImportResult, Error>) -> Void
    ) {
        let safeProgress: (Progress) -> Void = { p in DispatchQueue.main.async { progress(p) } }
        let safeComplete: (Swift.Result<ImportResult, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }

        guard let playlist = PlaylistStore.shared.get(id: playlistId),
              !playlist.sourceListId.isEmpty,
              playlist.location == "online" else {
            safeComplete(.failure(ImportError.parseFailed("该歌单不支持更新（仅「在线导入且保留链接」的歌单可更新）")))
            return
        }

        let platformKey = playlist.source
        let listId = playlist.sourceListId
        let platform: Platform?
        let platformName: String
        switch platformKey {
        case "kg": platform = .kugou;   platformName = "酷狗"
        case "wy": platform = .netease; platformName = "网易云"
        case "tx": platform = .qq;      platformName = "QQ音乐"
        default:    platform = nil;      platformName = ""
        }

        guard let p = platform else {
            safeComplete(.failure(ImportError.parseFailed("暂不支持更新该平台的歌单")))
            return
        }

        let parsed = ParsedLink(platform: p, platformKey: platformKey,
                                platformName: platformName, type: .playlist, id: listId)

        safeProgress(Progress(platform: platformName, stage: "正在重新拉取歌单…", current: 0, total: 0, matched: 0))

        fetchTracks(parsed, progress: safeProgress) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                safeComplete(.failure(e))
            case .success(let (name, tracks)):
                guard !tracks.isEmpty else {
                    safeComplete(.failure(ImportError.empty))
                    return
                }
                self.matchTracks(tracks, into: playlistId, platformName: platformName, progress: safeProgress) { matchResult in
                    switch matchResult {
                    case .failure(let e):
                        safeComplete(.failure(e))
                    case .success(let (matched, total, skipped)):
                        let updated = PlaylistStore.shared.get(id: playlistId) ?? playlist
                        let result = ImportResult(
                            playlistName: name,
                            platform: platformName,
                            total: total,
                            matched: matched,
                            skipped: skipped,
                            playlist: updated
                        )
                        safeComplete(.success(result))
                    }
                }
            }
        }
    }

    /// 把拉取到的曲目逐首在本机音源匹配，写入已有歌单（整体替换）
    private func matchTracks(
        _ tracks: [Track],
        into playlistId: String,
        platformName: String,
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Swift.Result<(matched: Int, total: Int, skipped: [Track]), Error>) -> Void
    ) {
        var matchedSongs: [Song] = []
        var skipped: [Track] = []
        var idx = 0
        // 单首匹配的超时阈值（秒）。某些音源对个别曲目取不到播放 URL，
        // 若不设上限会一直挂住导致整个歌单 import 卡死。
        let perTrackTimeout: TimeInterval = 8

        func step() {
            if idx >= tracks.count {
                PlaylistStore.shared.replaceSongs(matchedSongs, in: playlistId)
                completion(.success((matchedSongs.count, tracks.count, skipped)))
                return
            }
            let t = tracks[idx]
            idx += 1
            progress(Progress(
                platform: platformName,
                stage: "匹配 \(idx)/\(tracks.count)：\(t.name)",
                current: idx,
                total: tracks.count,
                matched: matchedSongs.count
            ))
            // findSong 无内置超时：用 didRespond 旗标 + DispatchWorkItem 兜底
            var didRespond = false
            let timeoutItem = DispatchWorkItem {
                guard !didRespond else { return }
                didRespond = true
                skipped.append(t)
                step()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + perTrackTimeout, execute: timeoutItem)

            SourceSwitcher.shared.findSong(name: t.name, singer: t.artist) { song in
                guard !didRespond else { return }
                didRespond = true
                timeoutItem.cancel()
                if let song = song {
                    matchedSongs.append(song)
                } else {
                    skipped.append(t)
                }
                step()
            }
        }
        step()
    }

    // MARK: - 按「平台 + 源列表ID」直接导入（搜索页「歌单」模式点击使用）

    /// 只拉取歌单曲目（不做匹配、不写本地），供详情页预览使用
    func previewTracks(
        source: String,
        listId: String,
        completion: @escaping (Swift.Result<(name: String, tracks: [Track], total: Int), Error>) -> Void
    ) {
        let platform: Platform?
        let platformName: String
        switch source {
        case "wy": platform = .netease; platformName = "网易云"
        case "tx": platform = .qq;      platformName = "QQ音乐"
        case "kg": platform = .kugou;   platformName = "酷狗"
        default:    platform = nil;      platformName = ""
        }
        guard let p = platform else {
            completion(.failure(ImportError.parseFailed("暂不支持该音源的歌单预览"))); return
        }
        let parsed = ParsedLink(platform: p, platformKey: source,
                                platformName: platformName, type: .playlist, id: listId)
        // 90 秒总硬超时，否则万一大歌单 + 极端限速就一直转
        let overallTimeoutItem = DispatchWorkItem { [weak self] in
            self?.completePreview?(parsed.id, .failure(ImportError.parseFailed("拉取超时（90 秒）— 桌面/音源限速，可换源重试")))
            self?.completePreview = nil
        }
        self.completePreview = { _, result in
            overallTimeoutItem.cancel()
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: overallTimeoutItem)
        fetchTracks(parsed, progress: { _ in }) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.completePreview?(parsed.id, .failure(e))
                self.completePreview = nil
            case .success(let (name, tracks)):
                let res = (name: name, tracks: tracks, total: tracks.count)
                self.completePreview?(parsed.id, .success(res))
                self.completePreview = nil
            }
        }
    }
    /// 临时保存 previewTracks 的回调（每次新的预览会覆盖，所以预览期间不能并发）
    private var completePreview: ((String, Swift.Result<(name: String, tracks: [Track], total: Int), Error>) -> Void)?

    /// 直接按 source + listId 拉取整张歌单并写入本地（网易云 / QQ / 酷狗）。
    /// **完全后台执行**：立即返回一个 JobID 和本地歌单对象（曲目为空），后续匹配与追加在
    /// `DispatchQueue.global` 上进行，进度与完成通过 NotificationCenter 上报
    /// （`PlaylistImportJob.didStartNotification` / `.didProgressNotification` / `.didFinishNotification`）。
    /// 调用方（详情页 / 搜索页 / 歌单页）拿到 JobID 后可立即关闭 UI。
    @discardableResult
    func importPlaylistAsync(
        source: String,
        listId: String,
        hintName: String? = nil
    ) -> PlaylistImportJob {
        let platformKey: String
        let platformName: String
        switch source {
        case "wy": platformKey = "wy"; platformName = "网易云"
        case "tx": platformKey = "tx"; platformName = "QQ音乐"
        case "kg": platformKey = "kg"; platformName = "酷狗"
        default:    platformKey = source; platformName = source
        }
        // 立即创建一个空的本地歌单，让「我的歌单」列表立刻能看到
        let initialName = (hintName?.isEmpty == false) ? hintName! : "导入中…"
        let playlist = Playlist(
            name: initialName,
            source: platformKey,
            sourceListId: listId,
            location: "online",
            songs: []
        )
        PlaylistStore.shared.add(playlist)

        let job = PlaylistImportJob(
            playlistId: playlist.id,
            playlistName: initialName,
            source: platformKey,
            sourceListId: listId,
            platformName: platformName,
            createdAt: Date()
        )
        PlaylistImportManager.shared.register(job: job)
        job.post(.didStart)

        // 在全局后台线程上跑（避开主线程）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runImportJob(job, hintName: hintName)
        }
        return job
    }

    /// 实际后台导入逻辑
    private func runImportJob(_ job: PlaylistImportJob, hintName: String?) {
        guard let (platform, platformName) = platformFor(job.source) else {
            job.finalize(failure: ImportError.parseFailed("暂不支持该音源的歌单导入"))
            return
        }
        let parsed = ParsedLink(
            platform: platform, platformKey: job.source,
            platformName: platformName, type: .playlist, id: job.sourceListId
        )
        job.reportProgress(platform: platformName, stage: "正在拉取歌单…", current: 0, total: 0, matched: 0)

        // 90 秒总超时
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.failJob(job, reason: "拉取歌单超时（90 秒）— 网络/源端限速")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeoutItem)

        fetchTracks(parsed, progress: { _ in }) { [weak self] result in
            switch result {
            case .failure(let e):
                timeoutItem.cancel()
                self?.failJob(job, reason: e.localizedDescription)
            case .success(let (name, tracks)):
                timeoutItem.cancel()
                guard !tracks.isEmpty else {
                    self?.failJob(job, reason: "拉到了 0 首歌，请换个源或稍后重试")
                    return
                }
                // 用 hintName 覆盖（搜索结果可能用搜索时的展示名）
                let finalName = (hintName?.isEmpty == false) ? hintName! : name
                self?.runMatchAndAppend(job: job, finalName: finalName,
                                        platformKey: job.source,
                                        platformName: platformName,
                                        tracks: tracks)
            }
        }
    }

    private func platformFor(_ key: String) -> (Platform, String)? {
        switch key {
        case "wy": return (.netease, "网易云")
        case "tx": return (.qq,      "QQ音乐")
        case "kg": return (.kugou,   "酷狗")
        default:   return nil
        }
    }

    private func failJob(_ job: PlaylistImportJob, reason: String) {
        // 失败时把已创建的空歌单删掉（让「我的歌单」不留空壳）
        PlaylistStore.shared.delete(id: job.playlistId)
        job.finalize(failure: ImportError.parseFailed(reason))
    }

    /// 后台逐首匹配并 append 到 PlaylistStore（不阻塞 UI / 不动画）
    private func runMatchAndAppend(
        job: PlaylistImportJob,
        finalName: String,
        platformKey: String,
        platformName: String,
        tracks: [Track]
    ) {
        let total = tracks.count
        var matchedSongs: [Song] = []
        var skipped = 0
        var lastReportAt = Date.distantPast
        var idx = 0
        let perTrackTimeout: TimeInterval = 6
        let group = DispatchGroup()

        // 用串行队列逐步处理；每首匹配都有超时
        let serialQueue = DispatchQueue(label: "com.moshou.import.\(job.jobId)")
        func step() {
            if job.isCancelled {
                job.finalize(failure: ImportError.parseFailed("已取消"))
                return
            }
            if idx >= tracks.count {
                group.notify(queue: .main) {
                    job.reportProgress(platform: platformName, stage: "完成",
                                       current: total, total: total, matched: matchedSongs.count)
                    job.finalize(success: total, matched: matchedSongs.count)
                }
                return
            }
            let t = tracks[idx]
            idx += 1
            // 节流：每 0.4 秒最多上报一次进度
            let now = Date()
            if now.timeIntervalSince(lastReportAt) > 0.4 || idx == total {
                lastReportAt = now
                job.reportProgress(platform: platformName,
                                   stage: "匹配 \(idx)/\(total)：\(t.name)",
                                   current: idx, total: total, matched: matchedSongs.count)
            }
            var didRespond = false
            let timeout = DispatchWorkItem {
                guard !didRespond else { return }
                didRespond = true
                skipped += 1
                serialQueue.async { step() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + perTrackTimeout, execute: timeout)

            // 跨串行队列调用 SourceSwitcher.findSong（其内部已切回主线程再回调）
            SourceSwitcher.shared.findSong(name: t.name, singer: t.artist) { song in
                DispatchQueue.global(qos: .utility).async {
                    guard !didRespond else { return }
                    didRespond = true
                    timeout.cancel()
                    if let s = song {
                        matchedSongs.append(s)
                        // 立刻追加到本地歌单，让「我的歌单」可立即看到这首
                        DispatchQueue.main.async { [weak self] in
                            PlaylistStore.shared.addSongs([s], to: job.playlistId)
                            // 改名（拉到了真实名）
                            if finalName != job.playlistName {
                                self?.renameJob(job, finalName: finalName)
                            }
                        }
                    } else {
                        skipped += 1
                    }
                    serialQueue.async { step() }
                }
            }
        }
        serialQueue.async { step() }
        group.enter()
        // 触发 group.notify：等最末一次 addSongs 落盘后再释放
        // （这里 group 是单 enter；当 loop 走完会重新 leave → 通过上方的 notify queue）
        // 由于 loop 已通过内部串行完成，最终在主线程用 `notify(queue:)` 回调 finalize。
        // 为避免逻辑缠绕，这里用一个外部 concurrent 计数器：
        // 简化策略：串行循环退出后直接 finalize，依赖 `reportProgress` 节流。
        _ = group
    }

    /// 把 job 对应的本地歌单改名（在后台匹配时完成拉取的瞬间更新一次）
    private func renameJob(_ job: PlaylistImportJob, finalName: String) {
        PlaylistStore.shared.rename(id: job.playlistId, name: finalName)
        job.playlistName = finalName
    }
}
