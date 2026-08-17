import Foundation

/// 脚本管理器 — 管理多个音源脚本的加载/切换/导入
class ScriptManager {

    static let shared = ScriptManager()

    private(set) var loadedScripts: [ScriptInfo] = []

    struct ScriptInfo {
        let name: String
        let fileName: String
        let isBuiltin: Bool
        var sources: [String]
        var enabled: Bool
    }

    private init() {
        scanScripts()
    }

    // MARK: - 扫描脚本

    func scanScripts() {
        loadedScripts.removeAll()

        // 内置脚本
        let builtinNames = ["kw", "tx", "mg", "wy", "kg"]
        for name in builtinNames {
            let info = ScriptInfo(
                name: sourceDisplayName(name),
                fileName: "\(name).js",
                isBuiltin: true,
                sources: [name],
                enabled: ConfigStore.shared.isSourceEnabled(name)
            )
            loadedScripts.append(info)
        }

        // 用户脚本
        let scriptsDir = ConfigStore.shared.scriptsDirectory
        if FileManager.default.fileExists(atPath: scriptsDir.path) {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: scriptsDir.path) {
                for file in files where file.hasSuffix(".js") {
                    let name = (file as NSString).deletingPathExtension
                    let info = ScriptInfo(
                        name: name,
                        fileName: file,
                        isBuiltin: false,
                        sources: [name],
                        enabled: true
                    )
                    loadedScripts.append(info)
                }
            }
        }
    }

    // MARK: - 导入脚本

    func importScript(url: URL) -> Bool {
        let scriptsDir = ConfigStore.shared.scriptsDirectory

        do {
            // 创建目录
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

            let destURL = scriptsDir.appendingPathComponent(url.lastPathComponent)

            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }

            try FileManager.default.copyItem(at: url, to: destURL)

            // 加载脚本
            if let script = try? String(contentsOf: destURL, encoding: .utf8) {
                ScriptEngine.shared.loadCustomScript(script, name: url.lastPathComponent)
            }

            scanScripts()
            Logger.info("导入脚本成功: \(url.lastPathComponent)")
            return true

        } catch {
            Logger.error("导入脚本失败: \(error)")
            return false
        }
    }

    // MARK: - 切换源开关

    func toggleSource(_ source: String, enabled: Bool) {
        ConfigStore.shared.setSource(source, enabled: enabled)
        scanScripts()
    }

    // MARK: - 获取可用源

    var availableSources: [String] {
        let allSources = ["kw", "tx", "mg", "wy", "kg"]
        return allSources.filter { ConfigStore.shared.isSourceEnabled($0) }
    }

    // MARK: - 显示名

    func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "kw": return "酷我"
        case "tx": return "QQ音乐"
        case "mg": return "咪咕"
        case "wy": return "网易云"
        case "kg": return "酷狗"
        default: return source.uppercased()
        }
    }
}
