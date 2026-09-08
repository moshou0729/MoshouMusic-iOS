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
        // v1.0.83：歌名先去括号（不把 (Live)/（伴奏）带进搜索词），否则引擎倾向返回现场版/伴奏版
        let cleanName = Self.cleanSearchName(name)
        let keyword = singer.isEmpty || singer == "未知歌手" ? cleanName : "\(cleanName) \(singer)"

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

        // v1.0.83：同上，搜索词用干净歌名
        let cleanName = Self.cleanSearchName(name)
        let keyword = singer.isEmpty || singer == "未知歌手" ? cleanName : "\(cleanName) \(singer)"
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
    ///
    /// v1.0.88 强化（治「播的不是显示的版本」「中文歌名播外语歌」）：
    /// - 歌名从「子串沾边就算」改为「归一化后完全相等，或只差版本后缀（Live/伴奏/版…）」，
    ///   杜绝「晴天娃娃」靠 contains 命中「晴天」这类撞名错播。
    /// - 语言防线：目标歌名含中日韩文字时，候选必须同样含中日韩文字（反之亦然）。
    static func bestMatch(in songs: [Song], name: String, singer: String) -> Song? {
        guard !songs.isEmpty else { return nil }

        let targetName = normalize(name)
        let targetSingers = singerTokens(singer)

        var best: (song: Song, score: Int)?

        for song in songs {
            let n = normalize(song.name)
            // v1.0.88：语言防线 —— 显示中文歌名播外语歌的主通道
            guard languageCompatible(target: targetName, candidate: n) else { continue }
            // v1.0.89：语言版本标记一致性 —— 在剥括号前的原始名上检查。
            // 「当那一天来临 (English Ver.)」归一化剥括号后与「当那一天来临」完全同形，
            // 会绕过上面的 CJK 防线并拿到「精确同名」满分，实测导致赤旗版搜出英文歌。
            guard languageMarkers(in: name) == languageMarkers(in: song.name) else { continue }

            var score: Int
            switch nameRelation(candidate: n, target: targetName, targetSingers: targetSingers) {
            case .none:
                continue // 歌名完全不沾边就跳过
            case .exact:
                score = 100
            case .versionVariant:
                score = 55 // 可接受的版本变体，但要输给完全同名者
            }

            if !targetSingers.isEmpty {
                let s = singerTokens(song.singer)
                // v1.0.83：目标歌手非空时，**歌手无关的候选直接出局**——
                // 旧逻辑只对歌手轻微加分，可能让「歌手对不上的同名翻唱」靠歌名满分胜出，
                // 播出来歌手跟歌单对不上。现在只允许「与目标有共同歌手」的候选参与竞争。
                guard !s.isEmpty, !s.isDisjoint(with: targetSingers) else { continue }
                // 候选歌手覆盖全部目标歌手更强（不漏合作者）
                score += s.isSuperset(of: targetSingers) ? 40 : 20
            }

            // v1.0.83：原版启发式 —— 原唱/原版加分，live/翻唱/伴奏/remix 降权，
            // 避免「歌手对但版本错」（搜到现场版/翻唱版/伴奏版）。
            score += song.originalScore

            // 有时长信息的更可信
            if song.interval > 0 { score += 5 }

            if best == nil || score > best!.score {
                best = (song, score)
            }
        }

        // 目标歌手非空但没有任何候选歌手能匹配 → 返回 nil（上层会自动跳下一首/换源），
        // 绝不在歌手对不上的候选中硬挑一个播。v1.0.59 不变量。
        return best?.song
    }

    // MARK: - v1.0.88 歌名严格匹配 / 语言防线

    private enum NameRelation { case none, exact, versionVariant }

    /// 歌名关系判定：归一化后相等，或只差「版本后缀 / 歌手连写」，否则视为不同歌。
    private static func nameRelation(candidate: String, target: String, targetSingers: Set<String>) -> NameRelation {
        if candidate == target { return .exact }
        // 候选 = 目标 + 尾巴（如「起风了live」对「起风了」）
        if candidate.hasPrefix(target) {
            let rem = String(candidate.dropFirst(target.count))
            if isVersionSuffix(rem) || containsSingerToken(rem, targetSingers) { return .versionVariant }
        }
        // 目标 = 候选 + 尾巴（歌单里带后缀而源里是干名）
        if target.hasPrefix(candidate) {
            let rem = String(target.dropFirst(candidate.count))
            if isVersionSuffix(rem) || containsSingerToken(rem, targetSingers) { return .versionVariant }
        }
        return .none
    }

    /// 尾巴是否只是版本修饰词（live/伴奏/版…）。剩余内容不含任何版本词 → 不是同一首歌。
    private static func isVersionSuffix(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -_·•~~"))
        guard !s.isEmpty else { return false }
        s = s.lowercased()
        let keywords = ["live", "cover", "remix", "demo", "acoustic", "instrumental",
                        "inst", "ver", "version", "版", "现场", "翻唱", "伴奏", "钢琴",
                        "吉他", "演奏", "弹唱", "纯音乐", "清唱", "慢摇", "电音", "混音"]
        return keywords.contains { s.contains($0) }
    }

    /// 尾巴里含目标歌手名（音源把「歌名歌手」连写，如「起风了买辣椒也用券」）
    private static func containsSingerToken(_ raw: String, _ targetSingers: Set<String>) -> Bool {
        guard !targetSingers.isEmpty else { return false }
        let s = raw.lowercased()
        return targetSingers.contains { !s.isEmpty && s.contains($0) }
    }

    /// v1.0.88：语言防线 —— 目标与候选的歌名必须「同为含中日韩文字」或「同为不含」，
    /// 否则视为不同语言的歌曲直接出局。纯符号/数字歌名（双方都不含 CJK）不设防。
    private static func languageCompatible(target: String, candidate: String) -> Bool {
        return containsCJK(target) == containsCJK(candidate)
    }

    // MARK: - v1.0.89 语言版本标记（English Ver. / 英文版 等）

    /// 语言版本标记 → 归一语言码。在**原始歌名**（含括号内容）上匹配；
    /// 目标与候选的标记集合必须完全一致，否则该候选弃选。
    /// 例：目标「当那一天来临（赤旗版）」标记 ∅，候选「当那一天来临 (English Ver.)」
    /// 标记 {en} → 不一致弃选；目标「后来(英文版)」标记 {en} 只允许同为 {en} 的候选。
    static let matchLanguageGuardNote = "语言版本标记不一致的候选一律弃选，防中文歌名播外语版本"

    private static let languageMarkerMap: [(marker: String, lang: String)] = [
        ("english", "en"), ("英文", "en"), ("英语", "en"),
        ("japanese", "ja"), ("日语", "ja"), ("日文", "ja"),
        ("korean", "ko"), ("韩语", "ko"), ("韩文", "ko"),
        ("chinese", "zh"), ("中文", "zh"), ("国语", "zh"), ("普通话", "zh"), ("mandarin", "zh"),
        ("cantonese", "yue"), ("粤语", "yue"), ("粵語", "yue"),
        ("french", "fr"), ("法语", "fr"), ("法語", "fr"),
        ("german", "de"), ("德语", "de"), ("德語", "de"),
        ("russian", "ru"), ("俄语", "ru"), ("俄語", "ru"),
        ("spanish", "es"), ("西语", "es"), ("西語", "es"),
        ("thai", "th"), ("泰语", "th"), ("泰文", "th"),
    ]

    private static func languageMarkers(in rawName: String) -> Set<String> {
        let s = rawName.lowercased()
        var result = Set<String>()
        for (marker, lang) in languageMarkerMap where s.contains(marker) {
            result.insert(lang)
        }
        return result
    }

    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF,    // 平假名 / 片假名
                 0x3400...0x4DBF,    // CJK 扩展 A
                 0x4E00...0x9FFF,    // CJK 基本区
                 0xAC00...0xD7AF,    // 谚文
                 0xF900...0xFAFF,    // CJK 兼容
                 0x20000...0x2A6DF:  // CJK 扩展 B
                return true
            default:
                continue
            }
        }
        return false
    }

    /// v1.0.83：歌手名切 token —— 按常见分隔符（/ 、& feat with 空格等）拆分后逐个归一。
    /// 目标"周深"命中"周深/李克勤"（交集非空，可接受合作版），
    /// 但不再命中"周深模仿秀"这种只是名字含子串的无关歌手。
    private static func singerTokens(_ raw: String) -> Set<String> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "未知歌手" { return [] }
        s = s.lowercased()
            .replacingOccurrences(of: "feat.", with: "/", options: [])
            .replacingOccurrences(of: "feat", with: "/", options: [])
            .replacingOccurrences(of: "ft.", with: "/", options: [])
            .replacingOccurrences(of: "ft", with: "/", options: [])
            .replacingOccurrences(of: " with ", with: "/")
            .replacingOccurrences(of: " and ", with: "/")
            .replacingOccurrences(of: "&", with: "/")
            .replacingOccurrences(of: "×", with: "/")
            .replacingOccurrences(of: "、", with: "/")
        var result = Set<String>()
        let seps = CharacterSet(charactersIn: "/,，;；·")
        for piece in s.components(separatedBy: seps) {
            for sub in piece.components(separatedBy: .whitespacesAndNewlines) {
                let t = normalize(sub)
                if !t.isEmpty { result.insert(t) }
            }
        }
        return result
    }

    /// v1.0.83：搜索关键词用干净歌名（去掉 (Live)/（伴奏）等括号后缀），
    /// 避免把 "(Live)" 之类带进搜索词导致引擎只返回现场版/伴奏版。
    private static func cleanSearchName(_ raw: String) -> String {
        let patterns = ["\\([^)]*\\)", "（[^）]*）", "\\[[^\\]]*\\]", "【[^】]*】"]
        var t = raw
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
