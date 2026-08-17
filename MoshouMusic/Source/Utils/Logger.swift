import Foundation

/// 日志工具
class Logger {
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

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        guard isDebug else { return }
        let fileName = (file as NSString).lastPathComponent
        print("🔵 [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)")
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        print("🟢 [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)")
    }

    static func warn(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        print("🟡 [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)")
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        print("🔴 [\(dateFormatter.string(from: Date()))] [\(fileName):\(line)] \(message)")
    }
}
