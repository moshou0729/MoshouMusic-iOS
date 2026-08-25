import Foundation

/// 自动换源 — 当前音源拿不到播放链接时，去其他音源找同一首歌
///
/// 与旧版的区别：旧版只是「通知一下换源」但不真正找歌，导致失败被静默吞掉。
/// 现在是真正干活：在候选音源里依次「按歌名+歌手搜索 → 匹配 → 取播放链接」，
/// 全部串行执行（JSContext 非线程安全），任一成功即返回。
final class SourceSwitcher {

    /// 换源优先级：酷我最稳，其次酷狗，再到 QQ / 网易云 / 咪咕
    private let preferredOrder = ["kw", "kg", "tx", "wy", "mg"]

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

        ScriptEngine.shared.search(keyword: keyword, page: 1, source: source) { result in
            DispatchQueue.main.async {
                guard case .success(let rawList) = result, !rawList.isEmpty else {
                    Logger.warn("自动换源：\(source) 搜索无结果")
                    advance()
                    return
                }

                let songs = rawList.compactMap { Song(from: $0, source: source) }
                guard let matched = Self.bestMatch(in: songs, name: name, singer: singer) else {
                    Logger.warn("自动换源：\(source) 未匹配到同名歌曲")
                    advance()
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
                            Logger.info("自动换源成功：\(source) → \(matched.name) - \(matched.singer)")
                            completion(Hit(source: source, song: matched, url: url))
                        case .failure(let e):
                            Logger.warn("自动换源：\(source) 取链接失败 \(e.localizedDescription)")
                            advance()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 匹配打分

    /// 在搜索结果中挑最接近的一首
    static func bestMatch(in songs: [Song], name: String, singer: String) -> Song? {
        guard !songs.isEmpty else { return nil }

        let targetName = normalize(name)
        let targetSinger = normalize(singer)

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
