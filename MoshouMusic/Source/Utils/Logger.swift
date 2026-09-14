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
        // 🚨 v1.0.166：强制落盘 —— 本轮最关键的取证修正。
        // `UserDefaults.set` 只写入内存缓存，由系统在合适时机（数百 ms~数秒，
        // 或进入后台等事件）异步落盘；而进程被 jetsam 强杀时是 SIGKILL：
        // 不走 applicationWillTerminate、不产生崩溃报告，**所有未落盘的写入全部丢失**。
        // 后果：2026-09-14 11:35:48 那轮屏变拆窗后「一条屏变心跳都没留下」，一度被
        // 判读为「0.5s 内即被挂起」；实际上完全可能是心跳照常执行、只是没落盘。
        // ⚠️ 这同时意味着 v1.0.163~165 里所有「心跳断在第 N 条」的结论都要重新审视：
        // 断点是「最后一条落盘的日志」，而不是「最后一条执行的日志」。
        UserDefaults.standard.synchronize()
    }

    // MARK: - v1.0.166 存活探针（8 字节落盘，死亡时刻取证的最小代价手段）

    private static let aliveWallKey = "moshou_last_alive_wall_v1"
    private static let aliveUpKey = "moshou_last_alive_uptime_v1"

    /// 写一次「我还活着」—— 只写两个 Double 并强制落盘。
    ///
    /// 与 `persist()` 的区别：persist 会重写整条 150 项数组（约 15KB），
    /// 0.15s 一次的高频探针若走 persist，3 秒内就是近百次 15KB 写盘，
    /// 反而会把主线程和 I/O 拖住（更容易被杀）。高频采样一律用它；
    /// 需要可读日志时才用 persist。
    static func beatAlive() {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: aliveWallKey)
        d.set(ProcessInfo.processInfo.systemUptime, forKey: aliveUpKey)
        d.synchronize()
    }

    /// 上次存活时刻（墙钟，timeIntervalSince1970）；nil = 无记录
    static var lastAliveWallTs: Double? {
        let v = UserDefaults.standard.double(forKey: aliveWallKey)
        return v > 0 ? v : nil
    }

    /// 上次存活时刻（系统运行时间；设备重启才归零，可用于识别设备休眠造成的墙钟跳变）
    static var lastAliveUptime: Double? {
        let v = UserDefaults.standard.double(forKey: aliveUpKey)
        return v > 0 ? v : nil
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
