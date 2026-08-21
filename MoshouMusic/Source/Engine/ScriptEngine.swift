import JavaScriptCore
import Foundation

/// JS 脚本引擎 — 运行用户自定义音源脚本
/// 兼容 LXMusic 脚本格式，让社区现有脚本直接可用
///
/// 核心桥接对象:
/// - lx.request(url, options, callback) — HTTP 请求
/// - lx.send(eventName, data) — 发送事件
/// - lx.on(eventName, callback) — 注册事件监听
/// - lx.utils.crypto — 加密工具 (md5/aes/rsa/base64)
/// - lx.utils.buffer — 二进制处理
class ScriptEngine {

    static let shared = ScriptEngine()

    // MARK: - Properties

    private var context: JSContext!
    private var eventHandlers: [String: JSValue] = [:]

    /// 脚本支持的平台
    private(set) var supportedSources: [String] = []
    /// 脚本支持的音质
    private(set) var supportedQualities: [String] = []

    /// 是否已初始化
    private(set) var isInitialized = false

    // MARK: - Init

    private init() {
        setupContext()
        setupLXBridge()
        loadBuiltinScripts()
    }

    // MARK: - JSContext 初始化

    private func setupContext() {
        let virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)

        // 异常处理
        context.exceptionHandler = { _, exception in
            if let exception = exception {
                Logger.error("JS 异常: \(exception)")
            }
        }

        // 注入全局常量 (兼容 LXMusic)
        context.evaluateScript("""
            var EVENT_NAMES = {
                request: 'request',
                inited: 'inited',
                updateAlert: 'updateAlert'
            };
            var version = '1.0.0';
            var env = 'mobile';
        """)
    }

    // MARK: - lx 对象桥接 (核心)

    private func setupLXBridge() {
        let lx = JSValue(newObjectIn: context)!

        // === lx.request(url, options, callback) ===
        let requestBlock: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self]
            url, options, callback in
            self?.handleRequest(url: url, options: options, callback: callback)
        }
        lx.setObject(requestBlock, forKeyedSubscript: "request" as NSString)

        // === lx.send(eventName, data) ===
        let sendBlock: @convention(block) (String, JSValue) -> Void = { [weak self]
            eventName, data in
            self?.handleEvent(eventName, data: data)
        }
        lx.setObject(sendBlock, forKeyedSubscript: "send" as NSString)

        // === lx.on(eventName, callback) ===
        let onBlock: @convention(block) (String, JSValue) -> Void = { [weak self]
            eventName, callback in
            self?.registerHandler(eventName, callback: callback)
        }
        lx.setObject(onBlock, forKeyedSubscript: "on" as NSString)

        // === lx.utils ===
        let utils = JSValue(newObjectIn: context)!

        // lx.utils.crypto
        let crypto = JSValue(newObjectIn: context)!

        let md5Block: @convention(block) (String) -> String = { data in
            return Crypto.md5(data)
        }
        crypto.setObject(md5Block, forKeyedSubscript: "md5" as NSString)

        let sha256Block: @convention(block) (String) -> String = { data in
            return Crypto.sha256(data)
        }
        crypto.setObject(sha256Block, forKeyedSubscript: "sha256" as NSString)

        let aesEncryptBlock: @convention(block) (String, String, String) -> String = {
            data, key, mode in
            return Crypto.aesEncrypt(data, key: key, mode: mode)
        }
        crypto.setObject(aesEncryptBlock, forKeyedSubscript: "aesEncrypt" as NSString)

        let aesDecryptBlock: @convention(block) (String, String, String) -> String = {
            data, key, mode in
            return Crypto.aesDecrypt(data, key: key, mode: mode)
        }
        crypto.setObject(aesDecryptBlock, forKeyedSubscript: "aesDecrypt" as NSString)

        let rsaEncryptBlock: @convention(block) (String, String) -> String = {
            data, publicKey in
            return Crypto.rsaEncrypt(data, publicKey: publicKey)
        }
        crypto.setObject(rsaEncryptBlock, forKeyedSubscript: "rsaEncrypt" as NSString)

        let base64EncodeBlock: @convention(block) (String) -> String = { data in
            return Crypto.base64Encode(data)
        }
        crypto.setObject(base64EncodeBlock, forKeyedSubscript: "base64Encode" as NSString)

        let base64DecodeBlock: @convention(block) (String) -> String = { data in
            return Crypto.base64Decode(data)
        }
        crypto.setObject(base64DecodeBlock, forKeyedSubscript: "base64Decode" as NSString)

        let urlEncodeBlock: @convention(block) (String) -> String = { data in
            return Crypto.urlEncode(data)
        }
        crypto.setObject(urlEncodeBlock, forKeyedSubscript: "urlEncode" as NSString)

        utils.setObject(crypto, forKeyedSubscript: "crypto" as NSString)

        // lx.utils.buffer (模拟 Node.js Buffer)
        let buffer = JSValue(newObjectIn: context)!

        let bufFromBlock: @convention(block) (String) -> [Int32] = { str in
            return Array(str.utf8).map { Int32($0) }
        }
        buffer.setObject(bufFromBlock, forKeyedSubscript: "from" as NSString)

        let bufAllocBlock: @convention(block) (Int) -> [Int32] = { size in
            return [Int32](repeating: 0, count: size)
        }
        buffer.setObject(bufAllocBlock, forKeyedSubscript: "alloc" as NSString)

        utils.setObject(buffer, forKeyedSubscript: "buffer" as NSString)

        lx.setObject(utils, forKeyedSubscript: "utils" as NSString)

        // === 注入全局 lx ===
        context.setObject(lx, forKeyedSubscript: "lx" as NSString)

        // === console (调试用) ===
        let console = JSValue(newObjectIn: context)!

        let logBlock: @convention(block) (JSValue) -> Void = { msg in
            Logger.debug("JS: \(msg)")
        }
        console.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        console.setObject(logBlock, forKeyedSubscript: "info" as NSString)
        console.setObject(logBlock, forKeyedSubscript: "warn" as NSString)

        let errorBlock: @convention(block) (JSValue) -> Void = { msg in
            Logger.error("JS Error: \(msg)")
        }
        console.setObject(errorBlock, forKeyedSubscript: "error" as NSString)

        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // === JSON 全局对象 (JSC 内置，但确保存在) ===
        // JavaScriptCore 已内置 JSON 对象
    }

    // MARK: - 事件处理

    private func registerHandler(_ eventName: String, callback: JSValue) {
        eventHandlers[eventName] = callback
        Logger.info("注册事件处理器: \(eventName)")
    }

    private func handleEvent(_ eventName: String, data: JSValue) {
        switch eventName {
        case "inited":
            if let dict = data.toDictionary() as? [String: Any] {
                if let sources = dict["sources"] as? [String] {
                    supportedSources = sources
                }
                if let qualities = dict["qualities"] as? [String] {
                    supportedQualities = qualities
                }
            }
            isInitialized = true
            Logger.info("脚本初始化完成 — 源: \(supportedSources), 音质: \(supportedQualities)")

        case "updateAlert":
            Logger.info("脚本更新提醒")

        default:
            Logger.debug("未知事件: \(eventName)")
        }
    }

    // MARK: - HTTP 请求桥接

    private func handleRequest(url: String, options: JSValue, callback: JSValue) {
        let optionsDict = options.toDictionary() as? [String: Any] ?? [:]

        let method = optionsDict["method"] as? String ?? "GET"
        let headers = optionsDict["headers"] as? [String: String] ?? [:]
        let body = optionsDict["body"] as? String
        let timeout = (optionsDict["timeout"] as? Double) ?? 30
        let isBinary = (optionsDict["isBinary"] as? Bool) ?? false

        // 调用前保存 callback 防止被 GC
        let callbackRef = callback

        NetworkManager.shared.request(
            url: url,
            method: method,
            headers: headers,
            body: body,
            timeout: timeout,
            isBinary: isBinary
        ) { result in
            switch result {
            case .success(let response):
                let responseDict: [String: Any] = [
                    "statusCode": response.statusCode,
                    "headers": response.headers,
                    "body": response.body,
                    "raw": response.rawData?.base64EncodedString() ?? ""
                ]
                callbackRef.call(withArguments: [NSNull(), responseDict])

            case .failure(let error):
                let errorDict: [String: Any] = [
                    "message": error.localizedDescription,
                    "code": (error as NSError).code
                ]
                callbackRef.call(withArguments: [errorDict, NSNull()])
            }
        }
    }

    // MARK: - 脚本加载

    private func loadBuiltinScripts() {
        let scriptNames = ["kw", "tx", "mg", "wy", "kg"]

        for name in scriptNames {
            let path = Bundle.main.path(forResource: name, ofType: "js", inDirectory: "default_scripts")
                ?? Bundle.main.path(forResource: name, ofType: "js")
            if let path = path,
               let script = try? String(contentsOfFile: path, encoding: .utf8) {
                context.evaluateScript(script)
                Logger.info("加载内置脚本: \(name).js")
            }
        }

        // 加载用户自定义脚本
        loadUserScripts()
    }

    private func loadUserScripts() {
        let scriptsDir = ConfigStore.shared.scriptsDirectory

        guard FileManager.default.fileExists(atPath: scriptsDir.path) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: scriptsDir.path)
            for file in files where file.hasSuffix(".js") {
                let filePath = scriptsDir.appendingPathComponent(file)
                if let script = try? String(contentsOf: filePath, encoding: .utf8) {
                    context.evaluateScript(script)
                    Logger.info("加载用户脚本: \(file)")
                }
            }
        } catch {
            Logger.error("读取脚本目录失败: \(error)")
        }
    }

    func loadCustomScript(_ script: String, name: String) {
        context.evaluateScript(script)
        Logger.info("加载自定义脚本: \(name)")
    }

    // MARK: - 上层接口: 搜索

    /// 搜索音乐
    func search(
        keyword: String,
        page: Int = 1,
        source: String,
        completion: @escaping (Result<[[String: Any]], Error>) -> Void
    ) {
        guard let handler = eventHandlers["request"] else {
            completion(.failure(ScriptError.noHandler))
            return
        }

        let request: [String: Any] = [
            "source": source,
            "action": "musicSearch",
            "info": [
                "page": page,
                "keyword": keyword
            ]
        ]

        let callback: @convention(block) (JSValue, JSValue) -> Void = { error, data in
            if error.isNull || error.isUndefined {
                if let dict = data.toDictionary() as? [String: Any] {
                    if let list = dict["list"] as? [[String: Any]] {
                        completion(.success(list))
                        return
                    }
                }
                completion(.failure(ScriptError.invalidResponse))
            } else {
                completion(.failure(ScriptError.scriptError(error.toString())))
            }
        }

        let callbackValue = JSValue(object: callback, in: context)!
        handler.call(withArguments: [request, callbackValue])
    }

    // MARK: - 上层接口: 获取播放链接

    /// 获取音乐播放 URL
    func getMusicUrl(
        source: String,
        songId: String,
        quality: String = "320k",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let handler = eventHandlers["request"] else {
            completion(.failure(ScriptError.noHandler))
            return
        }

        let request: [String: Any] = [
            "source": source,
            "action": "musicUrl",
            "info": [
                "songmid": songId,
                "quality": quality
            ]
        ]

        let callback: @convention(block) (JSValue, JSValue) -> Void = { error, data in
            if error.isNull || error.isUndefined {
                if let dict = data.toDictionary() as? [String: Any],
                   let url = dict["url"] as? String, !url.isEmpty {
                    completion(.success(url))
                } else {
                    completion(.failure(ScriptError.invalidResponse))
                }
            } else {
                completion(.failure(ScriptError.scriptError(error.toString())))
            }
        }

        let callbackValue = JSValue(object: callback, in: context)!
        handler.call(withArguments: [request, callbackValue])
    }

    // MARK: - 上层接口: 获取歌词

    /// 获取歌词
    func getLyrics(
        source: String,
        songId: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let handler = eventHandlers["request"] else {
            completion(.failure(ScriptError.noHandler))
            return
        }

        let request: [String: Any] = [
            "source": source,
            "action": "lyric",
            "info": [
                "songmid": songId
            ]
        ]

        let callback: @convention(block) (JSValue, JSValue) -> Void = { error, data in
            if error.isNull || error.isUndefined {
                if let dict = data.toDictionary() as? [String: Any] {
                    let lyric = dict["lyric"] as? String ?? ""
                    let tlyric = dict["tlyric"] as? String ?? ""
                    completion(.success(lyric + (tlyric.isEmpty ? "" : "\n\(tlyric)")))
                } else {
                    completion(.failure(ScriptError.invalidResponse))
                }
            } else {
                completion(.failure(ScriptError.scriptError(error.toString())))
            }
        }

        let callbackValue = JSValue(object: callback, in: context)!
        handler.call(withArguments: [request, callbackValue])
    }

    // MARK: - 上层接口: 获取封面

    /// 获取封面图片 URL
    func getPic(
        source: String,
        songId: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let handler = eventHandlers["request"] else {
            completion(.failure(ScriptError.noHandler))
            return
        }

        let request: [String: Any] = [
            "source": source,
            "action": "pic",
            "info": [
                "songmid": songId
            ]
        ]

        let callback: @convention(block) (JSValue, JSValue) -> Void = { error, data in
            if error.isNull || error.isUndefined {
                if let dict = data.toDictionary() as? [String: Any],
                   let url = dict["url"] as? String {
                    completion(.success(url))
                } else {
                    completion(.failure(ScriptError.invalidResponse))
                }
            } else {
                completion(.failure(ScriptError.scriptError(error.toString())))
            }
        }

        let callbackValue = JSValue(object: callback, in: context)!
        handler.call(withArguments: [request, callbackValue])
    }
}

// MARK: - ScriptError

enum ScriptError: Error, LocalizedError {
    case noHandler
    case invalidResponse
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .noHandler:
            return "没有注册请求处理器"
        case .invalidResponse:
            return "脚本返回数据格式无效"
        case .scriptError(let msg):
            return "脚本错误: \(msg)"
        }
    }
}
