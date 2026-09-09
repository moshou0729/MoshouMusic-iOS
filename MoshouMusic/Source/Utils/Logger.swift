import Foundation

/// 日志工具 —— v1.0.116 增加内存环形缓冲，供诊断日志页前台展示 + 复制
class Logger {
    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static let maxLines = 500

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// 统一入口：拼行 + 写入环形缓冲（锁覆盖 DateFormatter，保证多线程安全）
    private static func log(_ emoji: String, _ message: String, file: String, line: Int) {
        lock.lock()
        defer { lock.unlock() }
        let fileName = (file as NSString).lastPathComponent
        let text = "\(emoji) [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)"
        print(text)
        buffer.append(text)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
    }

    /// 导出全部缓冲日志（诊断日志页展示 / 复制用）
    static func dumpText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.joined(separator: "\n")
    }

    /// 当前缓冲行数
    static var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// 清空缓冲
    static func clearBuffer() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        guard isDebug else { return }
        log("🔵", message, file: file, line: line)
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log("🟢", message, file: file, line: line)
    }

    static func warn(_ message: String, file: String = #file, line: Int = #line) {
        log("🟡", message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log("🔴", message, file: file, line: line)
    }
}
