import Foundation

/// 自动换源 — 当前音源拿不到播放链接时，去其他音源找同一首歌
///
/// 与旧版的区别：旧版只是「通知一下换源」但不真正找歌，导致失败被静默吞掉。
/// 现在是真正干活：在候选音源里依次「按歌名+歌手搜索 → 匹配 → 取播放链接」，
/// 全部串行执行（JSContext 非线程安全），任一成功即返回。
final class SourceSwitcher {

    static let shared = SourceSwitcher()

    /// 换源优先级：酷狗最稳，其次 QQ / 网易云 / 咪咕
    private let preferredOrder = ["kg", "tx", "wy", "mg"]

    struct Hit {
        let source: String
        let song: Song
        let url: String
    }

    /// 在候选音源中依次尝试找到可播放的同名歌曲
    /// - Parameters:
    ///   - name: 歌曲名
    ///   - singer: 歌手名
    ///   - excluding: 需要跳过的音源（通常是已失败的当前源）
    ///   - quality: 目标音质
    ///   - completion: 成功返回 Hit，全部失败返回 nil
    func findPlayable(
        name: String,
        singer: String,
        excluding excluded: Set<String>,
        quality: String,
        completion: @escaping (Hit?) -> Void
    ) {
        let enabled = ConfigStore.shared.enabledSources
        // 只在「已启用 + 脚本已加载 + 未被排除」的音源里找
        let candidates = preferredOrder.filter {
            enabled.contains($0)
                && ScriptEngine.shared.hasHandler(for: $0)
                && !excluded.contains($0)
        }

        guard !candidates.isEmpty else {
            Logger.warn("自动换源：没有可用的候选音源")
            completion(nil)
            return
        }

        Logger.info("自动换源：候选 \(candidates.joined(separator: " → "))")
        tryNext(candidates, index: 0, name: name, singer: singer,
                quality: quality, completion: completion)
    }

    // MARK: - 串行递归尝试

    private func tryNext(
        _ candidates: [String],
        index: Int,
        name: String,
        singer: String,
        quality: String,
        completion: @escaping (Hit?) -> Void
    ) {
        guard index < candidates.count else {
            Logger.error("自动换源：所有候选音源均失败")
            completion(nil)
            return
        }

        let source = candidates[index]
        let advance = { [weak self] in
            self?.tryNext(candidates, index: index + 1, name: name,
                          singer: singer, quality: quality, completion: completion)
        }

        // 关键词带上歌手，提高匹配准确度
        let keyword = singer.isEmpty || singer == "未知歌手" ? name : "\(name) \(singer)"

        // 1) 先试内置源（ScriptEngine）
        attemptBuiltin(source: source, keyword: keyword, name: name, singer: singer, quality: quality) { [weak self] hit in
            if let hit = hit {
                completion(hit)
                return
            }
            // 2) 内置失败 → 再试用户导入的 7 个 LX 社区音源（不同后端，常能绕过版权/地域限制）
            self?.attemptLX(source: source, keyword: keyword, name: name, singer: singer, quality: quality) { lxHit in
                if let lxHit = lxHit {
                    completion(lxHit)
                } else {
                    advance()
                }
            }
        }
    }

    /// 用内置音源（ScriptEngine）搜索 + 取链接
    private func attemptBuiltin(
        source: String, keyword: String, name: String, singer: String, quality: String,
        completion: @escaping (Hit?) -> Void
    ) {
        ScriptEngine.shared.search(keyword: keyword, page: 1, source: source) { result in
            DispatchQueue.main.async {
                guard case .success(let rawList) = result, !rawList.isEmpty else {
                    Logger.warn("自动换源(内置)：\(source) 搜索无结果")
                    completion(nil)
                    return
                }

                let songs = rawList.compactMap { Song(from: $0, source: source) }
                guard let matched = Self.bestMatch(in: songs, name: name, singer: singer) else {
                    Logger.warn("自动换源(内置)：\(source) 未匹配到同名歌曲")
                    completion(nil)
                    return
                }

                ScriptEngine.shared.getMusicUrl(
                    source: source,
                    songId: matched.songmid,
                    quality: quality,
                    extra: matched.meta ?? [:]
                ) { urlResult in
                    DispatchQueue.main.async {
                        switch urlResult {
                        case .success(let url):
                            Logger.info("自动换源成功(内置)：\(source) → \(matched.name) - \(matched.singer)")
                            completion(Hit(source: source, song: matched, url: url))
                        case .failure(let e):
                            Logger.warn("自动换源(内置)：\(source) 取链接失败 \(e.localizedDescription)")
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    /// 用 LX 社区音源（LXCompatEngine，即用户导入的 7 个自定义源）搜索 + 取链接
    private func attemptLX(
        source: String, keyword: String, name: String, singer: String, quality: String,
        completion: @escaping (Hit?) -> Void
    ) {
        guard LXCompatEngine.shared.isPlatformAvailable(source) else {
            completion(nil)
            return
        }
        LXCompatEngine.shared.search(keyword: keyword, platform: source, page: 1) { result in
            DispatchQueue.main.async {
                guard case .success(let rawList) = result, !rawList.isEmpty else {
                    Logger.warn("自动换源(LX)：\(source) 搜索无结果")
                    completion(nil)
                    return
                }

                let songs = rawList.compactMap { Song(from: $0, source: source) }
                guard let matched = Self.bestMatch(in: songs, name: name, singer: singer) else {
                    Logger.warn("自动换源(LX)：\(source) 未匹配到同名歌曲")
                    completion(nil)
                    return
                }

                LXCompatEngine.shared.getMusicUrl(
                    platform: source,
                    songId: matched.songmid,
                    quality: quality,
                    extra: matched.meta ?? [:]
                ) { urlResult in
                    DispatchQueue.main.async {
                        switch urlResult {
                        case .success(let url):
                            Logger.info("自动换源成功(LX)：\(source) → \(matched.name) - \(matched.singer)")
                            completion(Hit(source: source, song: matched, url: url))
                        case .failure(let e):
                            Logger.warn("自动换源(LX)：\(source) 取链接失败 \(e.localizedDescription)")
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 仅查找可匹配的 Song（不取播放链接）

    /// 歌单导入用：在已启用音源里按「歌名+歌手」搜索并匹配，返回第一个命中的 Song
    /// 与 findPlayable 的区别：不调用 getMusicUrl，不做播放兜底，速度更快、适合批量
    func findSong(name: String, singer: String, completion: @escaping (Song?) -> Void) {
        let enabled = ConfigStore.shared.enabledSources
        let candidates = preferredOrder.filter {
            enabled.contains($0) && ScriptEngine.shared.hasHandler(for: $0)
        }
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }

        let keyword = singer.isEmpty || singer == "未知歌手" ? name : "\(name) \(singer)"
        var idx = 0

        func step() {
            guard idx < candidates.count else {
                completion(nil)
                return
            }
            let source = candidates[idx]
            idx += 1
            attemptSearchBuiltin(source: source, keyword: keyword, name: name, singer: singer) { song in
                if let song = song {
                    completion(song)
                    return
                }
                self.attemptSearchLX(source: source, keyword: keyword, name: name, singer: singer) { lxSong in
                    if let lxSong = lxSong {
                        completion(lxSong)
                    } else {
                        step()
                    }
                }
            }
        }
        step()
    }

    private func attemptSearchBuiltin(
        source: String, keyword: String, name: String, singer: String,
        completion: @escaping (Song?) -> Void
    ) {
        ScriptEngine.shared.search(keyword: keyword, page: 1, source: source) { result in
            DispatchQueue.main.async {
                guard case .success(let rawList) = result, !rawList.isEmpty else {
                    completion(nil)
                    return
                }
                let songs = rawList.compactMap { Song(from: $0, source: source) }
                completion(SourceSwitcher.bestMatch(in: songs, name: name, singer: singer))
            }
        }
    }

    private func attemptSearchLX(
        source: String, keyword: String, name: String, singer: String,
        completion: @escaping (Song?) -> Void
    ) {
        guard LXCompatEngine.shared.isPlatformAvailable(source) else {
            completion(nil)
            return
        }
        LXCompatEngine.shared.search(keyword: keyword, platform: source, page: 1) { result in
            DispatchQueue.main.async {
                guard case .success(let rawList) = result, !rawList.isEmpty else {
                    completion(nil)
                    return
                }
                let songs = rawList.compactMap { Song(from: $0, source: source) }
                completion(SourceSwitcher.bestMatch(in: songs, name: name, singer: singer))
            }
        }
    }

    // MARK: - 匹配打分

    /// 在搜索结果中挑最接近的一首
    ///
    /// 匹配原则（F4 强化）：必须结合「歌名 + 歌手」。
    /// 旧逻辑只对歌手轻微加分，导致换源/导入时经常选中「歌名相同但歌手不对」的版本。
    /// 现在：
    /// - 目标歌手非空时，先判断是否存在「歌手对得上」的候选。
    /// - 若存在，则直接排除「歌手明显不符」的候选（不与其竞争），让歌手对得上的胜出。
    /// - 若不存在任何歌手对得上的候选（纯属音源歌手字段缺失/不一致），才退而求其次，
    ///   但仍对「歌手明显不符」者显著扣分，避免它排在前面。
    static func bestMatch(in songs: [Song], name: String, singer: String) -> Song? {
        guard !songs.isEmpty else { return nil }

        let targetName = normalize(name)
        let targetSinger = normalize(singer)

        // 先扫一遍：是否存在歌手能对应上的候选
        var hasSingerMatch = false
        if !targetSinger.isEmpty {
            for song in songs {
                let s = normalize(song.singer)
                if s == targetSinger || s.contains(targetSinger) || targetSinger.contains(s) {
                    hasSingerMatch = true
                    break
                }
            }
        }

        var best: (song: Song, score: Int)?

        for song in songs {
            let n = normalize(song.name)
            let s = normalize(song.singer)
            var score = 0

            if n == targetName { score += 100 }
            else if n.contains(targetName) || targetName.contains(n) { score += 60 }
            else { continue } // 歌名完全不沾边就跳过

            if !targetSinger.isEmpty {
                if s == targetSinger { score += 50 }
                else if s.contains(targetSinger) || targetSinger.contains(s) { score += 25 }
                else if s.isEmpty {
                    // 候选无歌手信息：中性，不加分也不重罚（避免误杀）
                    score += 0
                } else {
                    // 候选歌手与目标明显不符
                    if hasSingerMatch {
                        // 已有更对的候选，直接排除这首错的
                        continue
                    } else {
                        // 实在没有对的，只能退而求其次，但显著扣分
                        score -= 70
                    }
                }
            }

            // 有时长信息的更可信
            if song.interval > 0 { score += 5 }

            if best == nil || score > best!.score {
                best = (song, score)
            }
        }

        return best?.song
    }

    /// 归一化：去空格、括号内容、大小写、常见后缀
    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // 去掉括号及其内容（(Live) / （伴奏） 之类）
        let patterns = ["\\([^)]*\\)", "（[^）]*）", "\\[[^\\]]*\\]", "【[^】]*】"]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
