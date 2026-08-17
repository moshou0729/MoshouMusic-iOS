import Foundation

/// LRC 歌词行
struct LRCLine: Equatable {
    let time: Double   // 时间戳(秒)
    let text: String   // 歌词文本
    let translation: String? // 翻译歌词(可选)
}

/// LRC 歌词解析器
/// 支持 [mm:ss.xx] 格式的时间标签
class LRCParser {

    /// 解析 LRC 文本为歌词行数组
    static func parse(_ lrcText: String) -> [LRCLine] {
        var lines: [LRCLine] = []
        let rawLines = lrcText.components(separatedBy: .newlines)

        // 正则匹配时间标签: [mm:ss.xx] 或 [mm:ss.xxx]
        let timePattern = #"\[(\d{1,3}):(\d{1,2})([.:]\d{1,3})?\]"#
        let regex = try? NSRegularExpression(pattern: timePattern)

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // 查找所有时间标签
            let nsLine = line as NSString
            let matches = regex?.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) ?? []

            if matches.isEmpty { continue }

            // 提取歌词文本 (去掉时间标签后的部分)
            let lastMatch = matches.last!
            let lyricText = nsLine.substring(from: lastMatch.range.location + lastMatch.range.length)
                .trimmingCharacters(in: .whitespaces)

            // 一行可能有多个时间标签，如 [00:01.00][01:30.00]歌词
            for match in matches {
                let timeStr = nsLine.substring(with: match.range)
                if let time = parseTimeTag(timeStr) {
                    lines.append(LRCLine(time: time, text: lyricText, translation: nil))
                }
            }
        }

        // 按时间排序
        lines.sort { $0.time < $1.time }

        return lines
    }

    /// 解析带翻译的 LRC
    static func parseWithTranslation(_ lrcText: String, translation: String?) -> [LRCLine] {
        var lines = parse(lrcText)

        guard let translation = translation, !translation.isEmpty else {
            return lines
        }

        let translatedLines = parse(translation)

        // 匹配翻译到原文
        var translationMap: [Double: String] = [:]
        for line in translatedLines {
            translationMap[line.time] = line.text
        }

        lines = lines.map { line in
            // 精确匹配或近似匹配 (±0.1秒)
            let translated = translationMap[line.time]
                ?? translationMap.keys.filter { abs($0 - line.time) < 0.5 }
                    .compactMap { translationMap[$0] }
                    .first
            return LRCLine(time: line.time, text: line.text, translation: translated)
        }

        return lines
    }

    /// 解析时间标签 [mm:ss.xx] -> 秒
    private static func parseTimeTag(_ tag: String) -> Double? {
        // 去掉方括号
        let content = tag
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")

        let parts = content.replacingOccurrences(of: ":", with: ".").components(separatedBy: ".")

        guard parts.count >= 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else {
            return nil
        }

        var total = minutes * 60 + seconds

        // 毫秒部分
        if parts.count >= 3 {
            let ms = parts[2]
            // 补齐到3位
            let padded = ms.padding(toLength: 3, withPad: "0", startingAt: 0)
            if let milliseconds = Double(padded) {
                total += milliseconds / 1000.0
            }
        }

        return total
    }

    /// 根据当前播放时间找到对应的歌词索引
    static func findCurrentIndex(at time: Double, in lines: [LRCLine]) -> Int? {
        guard !lines.isEmpty else { return nil }

        // 二分查找
        var low = 0
        var high = lines.count - 1
        var result = 0

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }
}
