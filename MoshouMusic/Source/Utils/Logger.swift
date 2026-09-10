import Foundation
import Darwin

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

    // MARK: - v1.0.126 穿透进程生死的持久化事件日志
    // 环形缓冲随进程走，进程被系统杀死后现场全丢（用户每次捞到的都只有重启后的日志）。
    // 关键事件（亮灭屏/中断/保活/场景切换）即时写入 UserDefaults，跨进程存活，
    // 用于取证「上次会话是怎么死的」。
    private static let persistKey = "moshou_persist_log_v1"
    private static let persistMaxEntries = 150

    /// 当前进程内存足迹（MB）—— jetsam（内存回收杀进程）取证用
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    /// 持久化一条关键事件（立即落 UserDefaults，进程被杀也不丢）
    static func persist(_ message: String, file: String = #file, line: Int = #line) {
        let mem = footprintMB()
        log("⭐", "\(message)（内存 \(mem)MB）", file: file, line: line)
        let fileName = (file as NSString).lastPathComponent
        lock.lock()
        defer { lock.unlock() }
        var entries = UserDefaults.standard.stringArray(forKey: persistKey) ?? []
        entries.append("⭐ [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)（内存 \(mem)MB）")
        if entries.count > persistMaxEntries {
            entries.removeFirst(entries.count - persistMaxEntries)
        }
        UserDefaults.standard.set(entries, forKey: persistKey)
    }

    /// 导出持久化事件（跨进程存活；诊断页置于环形缓冲之前展示）
    /// v1.0.130：maxLines 支持只取最近 N 条（控制剪贴板体积）
    static func dumpPersistText(maxLines: Int = Int.max) -> String {
        var entries = UserDefaults.standard.stringArray(forKey: persistKey) ?? []
        if entries.count > maxLines {
            entries = Array(entries.suffix(maxLines))
        }
        return entries.joined(separator: "\n")
    }

    /// 清空持久化事件
    static func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: persistKey)
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
