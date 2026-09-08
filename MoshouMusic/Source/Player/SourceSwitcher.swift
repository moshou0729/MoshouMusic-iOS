import Foundation

/// v1.0.90：两路取链竞速计票——首个成功胜出（后续结果一律作废），两路都失败才上报失败。
/// 只在主线程使用，无需加锁。
///
/// 背景：旧版「内置源 → LX 兼容层」串行兜底，同步歌的内置官方源经常失效，
/// 每次都要等内置源 10s 超时才轮到洛雪脚本（dujia 1~3s 就能回），
/// 是「点歌要等十几秒才出声」的主要来源。
final class DualRace {
    private var finished = false
    private var failures = 0
    private let total: Int
    init(total: Int = 2) { self.total = total }

    /// success=true：首个成功返回 true（胜出），后续成功返回 false。
    /// success=false：全部失败时返回 true（此时应上报失败），否则 false。
    func settle(success: Bool) -> Bool {
        guard !finished else { return false }
        if success {
            finished = true
            return true
        }
        failures += 1
        if failures >= total {
            finished = true
            return true
        }
        return false
    }
}

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

    /// 在候选音源里找到可播放的同名歌曲
    /// - Parameters:
    ///   - name: 歌曲名
    ///   - singer: 歌手名
    ///   - excluding: 需要跳过的音源（通常是已失败的当前源）
    ///   - quality: 目标音质
    ///   - interval: 目标歌曲权威时长（秒），用于时长接近度过滤（同步歌传）
    ///   - completion: 成功返回 Hit，全部失败返回 nil
    func findPlayable(
        name: String,
        singer: String,
        excluding excluded: Set<String>,
        quality: String,
        interval: Int = 0,
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

        // 关键词带上歌手，提高匹配准确度
        // v1.0.83：歌名先去括号（不把 (Live)/（伴奏）带进搜索词），否则引擎倾向返回现场版/伴奏版
        // v1.0.91：版本标记（赤旗版/爆燃版 等实义改编版）要带进搜索词 —— 这类版本
        // 是真实存在的音源条目，不带标记搜出来全是原版
        let cleanName = Self.cleanSearchName(name)
        let editions = Self.editionMarkers(in: name)
        var baseKeyword = singer.isEmpty || singer == "未知歌手" ? cleanName : "\(cleanName) \(singer)"
        if !editions.isEmpty {
            baseKeyword += " " + editions.joined(separator: " ")
        }
        let keyword = baseKeyword

        // v1.0.95：全平台并行竞速 —— 旧版逐平台串行（每平台 内置+LX 竞速，全挂才下一个），
        // 「kg 挂 → 等 tx → 等 wy…」最坏可达数十秒。桌面端跨源兜底 1 秒出结果，
        // 说明各源后端本来就快，慢的是串行等待。现在所有平台（内置+LX）同时抢，
        // 首个有效结果胜出；准确性由 bestMatch 的歌名/歌手/版本标记/时长接近度把守，
        // 出声前还有音频时长预检兜底。
        let total = candidates.count * 2
        let race = DualRace(total: total)
        Logger.info("自动换源：全平台并行竞速 \(candidates.joined(separator: "+"))")

        let onFail: () -> Void = {
            if race.settle(success: false) {
                Logger.error("自动换源：所有候选音源均失败")
                completion(nil)
            }
        }
        let onHit: (Hit) -> Void = { hit in
            if race.settle(success: true) { completion(hit) }
        }

        for source in candidates {
            attemptBuiltin(source: source, keyword: keyword, name: name, singer: singer,
                           quality: quality, interval: interval) { hit in
                if let hit = hit { onHit(hit) } else { onFail() }
            }
            attemptLX(source: source, keyword: keyword, name: name, singer: singer,
                      quality: quality, interval: interval) { lxHit in
                if let lxHit = lxHit { onHit(lxHit) } else { onFail() }
            }
        }
    }

    /// 用内置音源（ScriptEngine）搜索 + 取链接
    private func attemptBuiltin(
        source: String, keyword: String, name: String, singer: String, quality: String,
        interval: Int = 0,
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
                guard let matched = Self.bestMatch(in: songs, name: name, singer: singer, targetInterval: interval) else {
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
        interval: Int = 0,
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
                guard let matched = Self.bestMatch(in: songs, name: name, singer: singer, targetInterval: interval) else {
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

        // v1.0.83：搜索词用干净歌名；v1.0.91：版本标记（X版）补回搜索词
        let cleanName = Self.cleanSearchName(name)
        let editions = Self.editionMarkers(in: name)
        var baseKeyword = singer.isEmpty || singer == "未知歌手" ? cleanName : "\(cleanName) \(singer)"
        if !editions.isEmpty {
            baseKeyword += " " + editions.joined(separator: " ")
        }
        let keyword = baseKeyword
        var idx = 0

        func step() {
            guard idx < candidates.count else {
                completion(nil)
                return
            }
            let source = candidates[idx]
            idx += 1
            // v1.0.90：同平台「内置 + LX」并行竞速，先匹配到先用；都失败换下一平台
            let race = DualRace()
            attemptSearchBuiltin(source: source, keyword: keyword, name: name, singer: singer) { song in
                if let song = song {
                    if race.settle(success: true) { completion(song) }
                    return
                }
                if race.settle(success: false) { step() }
            }
            attemptSearchLX(source: source, keyword: keyword, name: name, singer: singer) { lxSong in
                if let lxSong = lxSong {
                    if race.settle(success: true) { completion(lxSong) }
                    return
                }
                if race.settle(success: false) { step() }
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
        interval: Int = 0,
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
                completion(SourceSwitcher.bestMatch(in: songs, name: name, singer: singer, targetInterval: interval))
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
    /// v1.0.94：targetInterval —— 目标歌曲的权威时长（秒，桌面同步/本地已知时传）。
    /// 候选带时长且与目标偏差超过 max(12s, 目标10%) 的直接出局：
    /// 翻唱/错版/伴奏版与原曲的时长普遍差几十秒，是「赤旗版播成原版」之外的
    /// 又一道硬防线。
    static func bestMatch(in songs: [Song], name: String, singer: String, targetInterval: Int = 0) -> Song? {
        guard !songs.isEmpty else { return nil }

        let targetName = normalize(name)
        let targetSingers = singerTokens(singer)
        // v1.0.91：版本标记（赤旗版/爆燃版 等实义改编版）——目标带标记时，
        // 候选必须含同样标记，否则弃选（搜「水手（赤旗版）」不能拿原版水手充数）
        let targetEditions = editionMarkers(in: name)
        let intervalTolerance = targetInterval > 0
            ? max(12.0, Double(targetInterval) * 0.10) : 0

        var best: (song: Song, score: Int)?

        for song in songs {
            let n = normalize(song.name)
            // v1.0.88：语言防线 —— 显示中文歌名播外语歌的主通道
            guard languageCompatible(target: targetName, candidate: n) else { continue }
            // v1.0.94：时长接近度
            if intervalTolerance > 0, song.interval > 0,
               abs(Double(song.interval - targetInterval)) > intervalTolerance {
                continue
            }
            // v1.0.89：语言版本标记一致性 —— 在剥括号前的原始名上检查。
            // 「当那一天来临 (English Ver.)」归一化剥括号后与「当那一天来临」完全同形，
            // 会绕过上面的 CJK 防线并拿到「精确同名」满分，实测导致赤旗版搜出英文歌。
            guard languageMarkers(in: name) == languageMarkers(in: song.name) else { continue }
            // v1.0.91：版本标记一致性。v1.0.95 宽限通道 —— 候选不含目标版本标记时，
            // 仅当「双方都带时长且在容差内」才允许降权参赛（换源兜底最后手段：
            // 各源对改编版的命名不一，宁播时长对得上的同名同歌手候选也不至于完全不播；
            // 出声前还有音频时长预检把最后一道关）。没有时长佐证的一律出局。
            var editionPenalty = 0
            if !targetEditions.isEmpty {
                let cn = song.name.lowercased()
                if !targetEditions.allSatisfy({ cn.contains($0) }) {
                    guard intervalTolerance > 0, song.interval > 0,
                          abs(Double(song.interval - targetInterval)) <= intervalTolerance
                    else { continue }
                    editionPenalty = 40
                }
            }

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

            // v1.0.95：版本标记宽限通道的候选降权，有严格标记匹配的候选时让位
            score -= editionPenalty

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

    // MARK: - v1.0.91 版本标记（赤旗版 / 爆燃版 / DJ版 等）

    /// 提取歌名括号里的「实义版本标记」：X版（X 为 1~6 个字且不是语言标记），
    /// 或含 remix/dj 的括号内容。语言版（英文版/粤语版…）归 v1.0.89 的 languageMarkers 管，
    /// 这里刻意排除。用于①拼进搜索词②bestMatch 强制候选含同样标记。
    static func editionMarkers(in rawName: String) -> [String] {
        let patterns = ["\\([^)]*\\)", "（[^）]*）", "\\[[^\\]]*\\]", "【[^】]*】"]
        var result: [String] = []
        for p in patterns {
            for seg in matches(of: p, in: rawName) {
                let inner = String(seg.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !inner.isEmpty else { continue }
                if languageMarkerMap.contains(where: { inner.contains($0.marker) }) { continue }
                let isEdition = (inner.hasSuffix("版") && inner.count >= 2 && inner.count <= 8)
                    || inner.contains("remix") || inner.contains("dj")
                if isEdition { result.append(inner) }
            }
        }
        return result
    }

    /// 正则提取（返回完整匹配串数组）
    private static func matches(of pattern: String, in s: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
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
