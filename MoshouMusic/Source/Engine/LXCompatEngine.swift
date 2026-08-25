import JavaScriptCore
import Foundation

/// LXCompatEngine — 让 lx-music 桌面端社区脚本在 iOS 14.7.1 (JSC，无 async/await) 上运行。
///
/// 关键约束与对策：
/// 1. iOS 14.7.1 的 JSC 不支持 async/await（iOS 15 才支持）→ 社区脚本必须先 Babel 转 ES5。
///    本工程在打包时已经把 7 个内置预设脚本预转成 ES5（见 Resources/lx_compat/presets/*.es5.js），
///    因此启动即可用、无需在设备上跑 Babel；用户自行粘贴导入的脚本才在设备端用 Babel 转译。
/// 2. lx-music 脚本用 globalThis.lx = { EVENT_NAMES, request, on, send, env, version, utils }，
///    与 App 内置脚本（回调式 lx.on(request, function(data, cb))）形态不同 → 每个脚本跑在【独立
///    JSContext】里，加载同名的 shim.js，互不污染内置 ScriptEngine 的 lx 命名空间。
/// 3. 脚本通过 lx.send('inited', {sources}) 声明平台（数组或 map），通过 lx.on('request', handler)
///    注册请求处理器。Swift 侧用 shim 暴露的 globalThis.__lxDispatch(action, source, info, cb) 派发。
/// 4. info 形态对接 lx-music：{ musicInfo: {...}, type: quality }，而不是内置脚本的 {songmid, quality}。
final class LXCompatEngine {

    static let shared = LXCompatEngine()

    // MARK: - 实例模型

    private struct Instance {
        let id: String
        let displayName: String
        let context: JSContext
        let platforms: [String]
        let isUser: Bool
    }

    private var instances: [String: Instance] = [:]
    private var platformIndex: [String: String] = [:]   // platform -> 第一个提供它的脚本 id
    private var loaded = false

    // bundle 内资源代码（首次注册时读取并缓存）
    private var shimCode: String?
    private var regenCode: String?
    private var promiseCode: String?
    private var babelCode: String?
    private var presetES5: [String: String] = [:]
    private var presetNames: [String: String] = [:]

    // 设备端 Babel 转译上下文（懒加载，仅用户导入时需要）
    private var transpileCtx: JSContext?

    private init() {}

    // MARK: - 加载（幂等，主线程）

    func ensureLoaded() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { self.ensureLoaded() }
            return
        }
        guard !loaded else { return }
        loaded = true

        loadResourceCode()
        loadPresetManifest()
        for (id, es5) in presetES5 {
            registerScript(id: id, es5Code: es5, displayName: presetNames[id] ?? id, isUser: false)
        }
        loadUserCachedScripts()
        Logger.info("LX 兼容层已加载，平台总数: \(platformIndex.count)")
    }

    // MARK: - 资源读取

    private func loadResourceCode() {
        let fm = FileManager.default
        func read(_ name: String, _ ext: String, dir: String? = "lx_compat") -> String? {
            guard let p = Bundle.main.path(forResource: name, ofType: ext, inDirectory: dir) else { return nil }
            return try? String(contentsOfFile: p, encoding: .utf8)
        }
        shimCode = read("shim", "js")
        regenCode = read("regenerator-runtime", "js")
        promiseCode = read("es6-promise.auto.min", "js")
        babelCode = read("babel-standalone.min", "js")
    }

    private func loadPresetManifest() {
        guard let p = Bundle.main.path(forResource: "manifest", ofType: "json", inDirectory: "lx_compat/presets"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let presets = json["presets"] as? [[String: Any]] else { return }
        for item in presets {
            guard let id = item["id"] as? String,
                  let file = item["file"] as? String,
                  let rawName = item["displayName"] as? String else { continue }
            // 预设已预转为 ES5，文件名形如 "hyw.es5.js"
            let (resName, resExt) = splitFileName(file)
            if let code = Bundle.main.path(forResource: resName, ofType: resExt, inDirectory: "lx_compat/presets")
                .flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
                presetES5[id] = code
                presetNames[id] = rawName
            }
        }
    }

    private func splitFileName(_ file: String) -> (String, String) {
        // "hyw.es5.js" -> ("hyw.es5", "js")
        let parts = file.components(separatedBy: ".")
        if parts.count >= 2 {
            let ext = parts.last!
            let name = parts.dropLast().joined(separator: ".")
            return (name, ext)
        }
        return (file, "js")
    }

    // MARK: - 注册单个脚本

    private func registerScript(id: String, es5Code: String, displayName: String, isUser: Bool) {
        guard instances[id] == nil else { return }
        guard let shim = shimCode, !es5Code.isEmpty else {
            Logger.error("LX[\(id)] 缺少 shim 或脚本代码，跳过")
            return
        }

        let vm = JSVirtualMachine()
        guard let ctx = JSContext(virtualMachine: vm) else {
            Logger.error("LX[\(id)] 无法创建 JSContext（内存不足？），跳过")
            return
        }
        ctx.exceptionHandler = { [weak self] _, ex in
            Logger.error("LX[\(id)] JS异常: \(ex?.description ?? "")")
        }

        var capturedInited: [String: Any]?
        injectBridges(into: ctx, scriptId: id) { name, data in
            if name == "inited", let d = data.toDictionary() as? [String: Any] {
                capturedInited = d
            }
        }

        if let regen = regenCode { ctx.evaluateScript(regen) }
        if let promise = promiseCode { ctx.evaluateScript(promise) }
        ctx.evaluateScript(shim)
        ctx.evaluateScript(es5Code)

        let platforms = parsePlatforms(from: capturedInited)
        guard !platforms.isEmpty else {
            Logger.warn("LX[\(id)] 未声明任何可用平台，跳过（可能是服务端脚本或已失效）")
            return
        }

        let inst = Instance(id: id, displayName: displayName, context: ctx,
                            platforms: platforms, isUser: isUser)
        instances[id] = inst
        for p in platforms where platformIndex[p] == nil {
            platformIndex[p] = id
        }
        Logger.info("LX 音源已加载: \(displayName) 平台=\(platforms.joined(separator: ","))")
    }

    // MARK: - 桥接注入

    private func injectBridges(into ctx: JSContext, scriptId: String,
                               onInited: @escaping (String, JSValue) -> Void) {
        let reqBlock: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] url, options, callback in
            self?.handleRequest(url: url, options: options, callback: callback, in: ctx)
        }
        ctx.setObject(reqBlock, forKeyedSubscript: "__lxRequest" as NSString)

        let sendBlock: @convention(block) (String, JSValue) -> Void = { name, data in
            onInited(name, data)
        }
        ctx.setObject(sendBlock, forKeyedSubscript: "__lxOnSend" as NSString)

        let md5Block: @convention(block) (String) -> String = { Crypto.md5($0) }
        ctx.setObject(md5Block, forKeyedSubscript: "__lxMd5" as NSString)

        let sha1Block: @convention(block) (String) -> String = { Crypto.sha1($0) }
        ctx.setObject(sha1Block, forKeyedSubscript: "__lxSha1" as NSString)
    }

    private func handleRequest(url: String, options: JSValue, callback: JSValue, in ctx: JSContext) {
        let opts = options.toDictionary() as? [String: Any] ?? [:]
        let method = opts["method"] as? String ?? "GET"
        let headers = opts["headers"] as? [String: String] ?? [:]
        let body = opts["body"] as? String
        let timeout = (opts["timeout"] as? Double) ?? 30
        let isBinary = (opts["isBinary"] as? Bool) ?? false
        let followRedirect = (opts["followRedirect"] as? Bool) ?? true

        NetworkManager.shared.request(
            url: url, method: method, headers: headers, body: body,
            timeout: timeout, isBinary: isBinary, followRedirect: followRedirect
        ) { result in
            let invoke: () -> Void = {
                switch result {
                case .success(let resp):
                    let d: [String: Any] = [
                        "statusCode": resp.statusCode,
                        "headers": resp.headers,
                        "body": resp.body,
                        "raw": resp.rawData?.base64EncodedString() ?? ""
                    ]
                    callback.call(withArguments: [NSNull(), d])
                case .failure(let err):
                    let e: [String: Any] = [
                        "message": err.localizedDescription,
                        "code": (err as NSError).code
                    ]
                    callback.call(withArguments: [e, NSNull()])
                }
            }
            if Thread.isMainThread { invoke() } else { DispatchQueue.main.async(execute: invoke) }
        }
    }

    // MARK: - inited 解析

    private func parsePlatforms(from inited: [String: Any]?) -> [String] {
        guard let inited = inited else { return [] }
        if let arr = inited["sources"] as? [String] {
            return arr.filter { !$0.isEmpty }
        }
        if let dict = inited["sources"] as? [String: Any] {
            return Array(dict.keys).filter { !$0.isEmpty }
        }
        return []
    }

    // MARK: - 对外查询

    var allPlatforms: [String] { Array(platformIndex.keys) }

    var scriptList: [(id: String, name: String, platforms: [String], isUser: Bool)] {
        instances.values.map { ($0.id, $0.displayName, $0.platforms, $0.isUser) }
            .sorted { $0.name < $1.name }
    }

    func providerName(forPlatform platform: String) -> String? {
        guard let id = platformIndex[platform] else { return nil }
        return instances[id]?.displayName
    }

    func isPlatformAvailable(_ platform: String) -> Bool {
        return platformIndex[platform] != nil
    }

    // MARK: - 统一派发

    private func buildInfo(songId: String, quality: String, extra: [String: String]) -> [String: Any] {
        var musicInfo: [String: Any] = ["songmid": songId, "hash": songId, "songId": songId]
        for (k, v) in extra where !k.isEmpty { musicInfo[k] = v }
        return ["musicInfo": musicInfo, "type": quality]
    }

    private final class CallbackBox { var finished = false }

    /// 在指定实例里派发一个 action，回调返回原始 data（Any）
    private func dispatch(in inst: Instance, action: String, platform: String,
                          info: [String: Any], timeout: Double,
                          completion: @escaping (Result<JSValue, Error>) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.dispatch(in: inst, action: action, platform: platform,
                               info: info, timeout: timeout, completion: completion)
            }
            return
        }
        guard let dispatchFn = inst.context.objectForKeyedSubscript("__lxDispatch"),
              !dispatchFn.isUndefined, !dispatchFn.isNull else {
            completion(.failure(LXError.noDispatch(inst.id)))
            return
        }

        let box = CallbackBox()
        let finish: (Result<JSValue, Error>) -> Void = { r in
            guard !box.finished else { return }
            box.finished = true
            completion(r)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !box.finished { Logger.warn("LX[\(inst.id)] 超时 \(action)/\(platform)") }
            finish(.failure(LXError.timeout(inst.id)))
        }

        let callback: @convention(block) (JSValue, JSValue) -> Void = { err, data in
            if err.isNull || err.isUndefined {
                finish(.success(data))
            } else {
                var msg = "脚本错误"
                if let d = err.toDictionary(), let m = d["message"] as? String, !m.isEmpty { msg = m }
                else if let s = err.toString(), !s.isEmpty, s != "undefined" { msg = s }
                finish(.failure(LXError.script("\(inst.id): \(msg)")))
            }
        }
        guard let cbVal = JSValue(object: callback, in: inst.context) else {
            finish(.failure(LXError.invalid(inst.id)))
            return
        }
        let infoVal = JSValue(object: info, in: inst.context) ?? JSValue(nullIn: inst.context)
        dispatchFn.call(withArguments: [action, platform, infoVal, cbVal])
    }

    // MARK: - 对外接口

    func getMusicUrl(platform: String, songId: String, quality: String,
                     extra: [String: String],
                     completion: @escaping (Result<String, Error>) -> Void) {
        ensureLoaded()
        guard let id = platformIndex[platform], let inst = instances[id] else {
            completion(.failure(LXError.noProvider(platform)))
            return
        }
        let info = buildInfo(songId: songId, quality: quality, extra: extra)
        dispatch(in: inst, action: "musicUrl", platform: platform, info: info, timeout: 22) { result in
            switch result {
            case .success(let data):
                if let url = Self.extractUrl(from: data) {
                    completion(.success(url))
                } else {
                    completion(.failure(LXError.noPlayUrl))
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    func getLyrics(platform: String, songId: String, extra: [String: String],
                   completion: @escaping (Result<String, Error>) -> Void) {
        ensureLoaded()
        guard let id = platformIndex[platform], let inst = instances[id] else {
            completion(.failure(LXError.noProvider(platform)))
            return
        }
        let info = buildInfo(songId: songId, quality: "", extra: extra)
        dispatch(in: inst, action: "lyric", platform: platform, info: info, timeout: 18) { result in
            switch result {
            case .success(let data):
                completion(.success(Self.extractLyric(from: data)))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    func getPic(platform: String, songId: String, extra: [String: String],
                completion: @escaping (Result<String, Error>) -> Void) {
        ensureLoaded()
        guard let id = platformIndex[platform], let inst = instances[id] else {
            completion(.failure(LXError.noProvider(platform)))
            return
        }
        let info = buildInfo(songId: songId, quality: "", extra: extra)
        dispatch(in: inst, action: "pic", platform: platform, info: info, timeout: 18) { result in
            switch result {
            case .success(let data):
                if let url = Self.extractUrl(from: data) {
                    completion(.success(url))
                } else {
                    completion(.failure(LXError.noPlayUrl))
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    // MARK: - 结果提取

    private static func extractUrl(from data: JSValue) -> String? {
        if let d = data.toDictionary() as? [String: Any] {
            if let u = d["url"] as? String, u.hasPrefix("http") { return u }
            if let inner = d["data"] as? [String: Any],
               let u = inner["url"] as? String, u.hasPrefix("http") { return u }
            if let u = d["playUrl"] as? String, u.hasPrefix("http") { return u }
            return nil
        }
        if let s = data.toString(), s.hasPrefix("http") { return s }
        return nil
    }

    private static func extractLyric(from data: JSValue) -> String {
        if let d = data.toDictionary() as? [String: Any] {
            let l = (d["lyric"] as? String) ?? ""
            let t = (d["tlyric"] as? String) ?? ""
            return l + (t.isEmpty ? "" : "\n" + t)
        }
        return data.toString() ?? ""
    }

    // MARK: - 用户导入（设备端 Babel 转译 + 缓存）

    private func userDir() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("lx_user_sources")
    }

    private func registryPath() -> URL {
        userDir().appendingPathComponent("registry.json")
    }

    private func readRegistry() -> [[String: String]] {
        guard let data = try? Data(contentsOf: registryPath()),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return arr
    }

    private func writeRegistry(_ list: [[String: String]]) {
        try? FileManager.default.createDirectory(at: userDir(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            try? data.write(to: registryPath())
        }
    }

    /// 导入用户粘贴的 lx-music 脚本：Babel 转 ES5 → 缓存 → 注册。
    /// - Returns: 是否成功，以及该脚本声明的平台（用于 UI 反馈）
    func importUserScript(id: String, displayName: String, rawCode: String,
                          completion: @escaping (Bool, [String]) -> Void) {
        ensureLoaded()
        let es5 = transpile(rawCode) ?? rawCode
        // 先尝试注册，确认能声明平台
        registerScript(id: id, es5Code: es5, displayName: displayName, isUser: true)
        if let inst = instances[id] {
            // 缓存到磁盘，下次启动直接加载
            try? FileManager.default.createDirectory(at: userDir(), withIntermediateDirectories: true)
            try? es5.write(to: userDir().appendingPathComponent("\(id).es5.js"),
                          atomically: true, encoding: .utf8)
            try? rawCode.write(to: userDir().appendingPathComponent("\(id).js"),
                               atomically: true, encoding: .utf8)
            var list = readRegistry()
            if !list.contains(where: { $0["id"] == id }) {
                list.append(["id": id, "displayName": displayName])
                writeRegistry(list)
            }
            completion(true, inst.platforms)
        } else {
            completion(false, [])
        }
    }

    private func loadUserCachedScripts() {
        let list = readRegistry()
        for item in list {
            guard let id = item["id"], let name = item["displayName"],
                  let es5 = try? String(contentsOf: userDir().appendingPathComponent("\(id).es5.js"),
                                        encoding: .utf8) else { continue }
            registerScript(id: id, es5Code: es5, displayName: name, isUser: true)
        }
    }

    func removeUserScript(id: String) {
        guard let inst = instances[id], inst.isUser else { return }
        for p in inst.platforms where platformIndex[p] == id {
            platformIndex.removeValue(forKey: p)
        }
        instances.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: userDir().appendingPathComponent("\(id).es5.js"))
        try? FileManager.default.removeItem(at: userDir().appendingPathComponent("\(id).js"))
        var list = readRegistry().filter { $0["id"] != id }
        writeRegistry(list)
    }

    // MARK: - 设备端 Babel 转译（仅用户脚本）

    private func transpile(_ code: String) -> String? {
        let ctx = transpileContext()
        guard let babel = ctx?.objectForKeyedSubscript("Babel"), !babel.isUndefined else {
            Logger.warn("LX: Babel 不可用，尝试原样加载（若脚本含 async/await 将在 iOS14 失败）")
            return nil
        }
        let opts: [String: Any] = ["plugins": ["transform-async-to-generator"], "sourceType": "script"]
        guard let optsVal = JSValue(object: opts, in: ctx),
              let res = babel.invokeMethod("transform", withArguments: [code, optsVal]),
              let es5 = res.objectForKeyedSubscript("code")?.toString(), !es5.isEmpty else {
            return nil
        }
        // 仍存在 for await...of 时升级到 regenerator 方案
        if es5.contains("for await") {
            let opts2: [String: Any] = ["plugins": ["transform-async-to-generator",
                                    "transform-async-generator-functions",
                                    "transform-regenerator"], "sourceType": "script"]
            if let opts2Val = JSValue(object: opts2, in: ctx),
               let res2 = babel.invokeMethod("transform", withArguments: [code, opts2Val]),
               let es5b = res2.objectForKeyedSubscript("code")?.toString(), !es5b.isEmpty {
                return es5b
            }
        }
        return es5
    }

    private func transpileContext() -> JSContext? {
        if let c = transpileCtx, c.exceptionHandler != nil { return c }
        guard let babel = babelCode else { return nil }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in Logger.error("LX Babel JS: \(ex?.description ?? "")") }
        // Babel standalone 需要 self/window 指向全局对象
        ctx.evaluateScript("var self = this; var window = this;")
        ctx.evaluateScript(babel)
        if let regen = regenCode { ctx.evaluateScript(regen) }
        transpileCtx = ctx
        return ctx
    }
}

// MARK: - 错误

enum LXError: Error, LocalizedError {
    case noProvider(String)
    case noDispatch(String)
    case timeout(String)
    case invalid(String)
    case script(String)
    case noPlayUrl

    var errorDescription: String? {
        switch self {
        case .noProvider(let p): return "没有可用的 LX 兼容音源提供平台 \(p)"
        case .noDispatch(let id): return "\(id) 未注入派发入口"
        case .timeout(let id): return "\(id) 响应超时"
        case .invalid(let id): return "\(id) 回调无效"
        case .script(let m): return m
        case .noPlayUrl: return "LX 音源未返回可用播放链接"
        }
    }
}
