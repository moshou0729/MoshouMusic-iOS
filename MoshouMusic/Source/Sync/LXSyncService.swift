import Foundation
import UIKit
import Security

/// LX Music 桌面版同步服务客户端（原生 WebSocket + message2call RPC）
///
/// 协议严格对齐 lx-music-desktop（dev 分支）：
/// - 认证：/hello → /id → /ah（RSA-2048 交换 clientId + AES key）
/// - 连接：ws(s)://host/socket?i=<clientId>&t=aesEncrypt("lx-music connect", key)
/// - 报文：明文 JSON，`>1024` 字节 gzip(标准 zlib) 加 `cg_` 前缀（见 LXSyncCrypto.encodeData/decodeData）
/// - RPC：message2call@0.1.3 线格式 `{name, path:[fn], data:[args]}` / 响应 `{name, error, data}`
///   服务端编排：getEnabledFeatures →（逐 feature）sync → finished。客户端作为被调方响应下列函数。
final class LXSyncService {

    // MARK: - 同步连接状态机

    enum Status: Equatable {
        case notConfigured           // 未填写服务地址
        case idle                    // 已配置但未连接
        case testing                 // 正在请求 /hello
        case ok(handshake: String, latencyMs: Int)   // 握手成功
        case connecting              // 正在做 HTTP 认证（/id、/ah、RSA 交换）
        case syncing                 // WebSocket 已连，服务端正在编排同步
        case synced(playlistCount: Int)            // 同步完成
        case failed(reason: String)  // 失败（含错误原因）
        case disconnected            // 连接已断开

        var displayText: String {
            switch self {
            case .notConfigured:        return "未配置"
            case .idle:                 return "已配置，未连接"
            case .testing:              return "正在测试…"
            case .ok(let h, let ms):    return "✓ 握手成功（\(ms)ms）\n服务器：\(h.prefix(60))"
            case .connecting:           return "正在认证…"
            case .syncing:              return "正在同步歌单…"
            case .synced(let n):        return "✓ 同步完成（\(n) 个歌单）"
            case .failed(let r):        return "✗ \(r)"
            case .disconnected:         return "连接已断开"
            }
        }

        var isConnected: Bool {
            switch self {
            case .ok, .synced: return true
            default:           return false
            }
        }
    }

    // message2call 被调函数签名：(参数数组, 完成回调)
    typealias Handler = (_ args: [Any], _ completion: @escaping (Result<Any?, Error>) -> Void) -> Void

    static let shared = LXSyncService()

    private(set) var status: Status = .notConfigured

    static let stateChangedNotification = Notification.Name("LXSyncStateChanged")

    // WebSocket 相关
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private let syncQueue = DispatchQueue(label: "com.moshou.lxsync")
    private var pending: [String: (Result<Any?, Error>) -> Void] = [:]
    private var handlers: [String: Handler] = [:]
    private var didSync = false

    private init() {
        registerHandlers()
        refreshInitialState()
    }

    // MARK: - 初始化状态

    func refreshInitialState() {
        let url = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        status = url.isEmpty ? .notConfigured : .idle
    }

    // MARK: - 公开控制

    /// 启动一次完整同步：输入桌面端显示的 6 位同步码
    func startSync(authCode: String) {
        stopSync()
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            status = .failed(reason: "请输入桌面端显示的 6 位同步码"); notify(); return
        }
        guard let hostPath = hostPathFromConfig() else {
            status = .failed(reason: "请先在上方填写同步服务地址"); notify(); return
        }
        didSync = false
        status = .connecting
        notify()

        getHello(hostPath) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.status = .failed(reason: "握手失败：\(e.localizedDescription)"); self.notify()
            case .success:
                self.getServerId(hostPath) { serverIdResult in
                    switch serverIdResult {
                    case .failure(let e):
                        self.status = .failed(reason: "获取服务 ID 失败：\(e.localizedDescription)"); self.notify()
                    case .success:
                        guard let (pub, priv) = LXSyncCrypto.generateRSAKeyPair() else {
                            self.status = .failed(reason: "RSA 密钥生成失败"); self.notify(); return
                        }
                        self.authWithCode(hostPath: hostPath, authCode: code,
                                         publicPEM: pub, privateKey: priv) { authResult in
                            switch authResult {
                            case .failure(let e):
                                self.status = .failed(reason: "认证失败：\(e.localizedDescription)"); self.notify()
                            case .success(let keyInfo):
                                self.connectWebSocket(hostPath: hostPath, keyInfo: keyInfo)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 停止同步并关闭 WebSocket
    func stopSync() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        syncQueue.async { self.pending.removeAll() }
        if case .synced = status {
            // 保留“已同步”标记，仅断开底层连接
        } else {
            status = .disconnected
            notify()
        }
    }

    // MARK: - HTTP 握手 / 认证

    private func hostPathFromConfig() -> String? {
        let raw = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return normalizeServerURL(raw)
    }

    private func getHello(_ hostPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        httpGet("\(hostPath)/hello") { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let body):
                if body.contains("Hello") {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "LXSync", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "服务未返回 Hello（可能不是 LX 同步服务）"])))
                }
            }
        }
    }

    private func getServerId(_ hostPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        httpGet("\(hostPath)/id") { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let body):
                let prefix = "OjppZDo6"
                if body.hasPrefix(prefix) {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "LXSync", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "无效的服务 ID（\(body.prefix(40))）"])))
                }
            }
        }
    }

    private func authWithCode(hostPath: String, authCode: String,
                              publicPEM: String, privateKey: SecKey,
                              completion: @escaping (Result<LXClientKeyInfo, Error>) -> Void) {
        let aesKey = LXSyncCrypto.keyFromAuthCode(authCode)
        let pubB64 = publicPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let deviceName = UIDevice.current.name
        // 对齐 client/auth.ts：lx-music auth::\n<pubKey>\n<deviceName>\nlx_music_desktop
        let plaintext = "lx-music auth::\n\(pubB64)\n\(deviceName)\nlx_music_desktop"
        let m = LXSyncCrypto.aesEncryptLX(plaintext: plaintext, keyBase64: aesKey)
        guard !m.isEmpty else {
            completion(.failure(NSError(domain: "LXSync", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "认证报文加密失败"]))); return
        }

        var req = URLRequest(url: URL(string: "\(hostPath)/ah")!)
        req.timeoutInterval = 10
        req.setValue(m, forHTTPHeaderField: "m")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "LXSync", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "认证无响应"]))); return
            }
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            guard http.statusCode == 200 else {
                let reason: String
                if body.contains("Blocked") { reason = "IP 被服务端封禁（请求过于频繁，稍后重试）" }
                else if body.contains("Auth failed") || body.contains("auth") { reason = "同步码错误或已失效" }
                else { reason = "认证返回 HTTP \(http.statusCode)" }
                completion(.failure(NSError(domain: "LXSync", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: reason]))); return
            }
            guard let plain = LXSyncCrypto.rsaOAEPDecrypt(base64Cipher: body, privateKey: privateKey),
                  let jsonStr = String(data: plain, encoding: .utf8),
                  let keyInfo = try? JSONDecoder().decode(LXClientKeyInfo.self, from: Data(jsonStr.utf8)) else {
                completion(.failure(NSError(domain: "LXSync", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "解析认证响应失败"]))); return
            }
            completion(.success(keyInfo))
        }.resume()
    }

    private func httpGet(_ urlString: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "LXSync", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "URL 非法"]))); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            completion(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
        }.resume()
    }

    // MARK: - WebSocket 连接

    private func connectWebSocket(hostPath: String, keyInfo: LXClientKeyInfo) {
        let wsURLString = hostPath
            .replacingOccurrences(of: "http", with: "ws", options: [.anchored])
            + "/socket"
        let t = LXSyncCrypto.aesEncryptLX(plaintext: "lx-music connect", keyBase64: keyInfo.key)
        guard let i = keyInfo.clientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let tEnc = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(wsURLString)?i=\(i)&t=\(tEnc)") else {
            status = .failed(reason: "构造 WebSocket 地址失败"); notify(); return
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.wsSession = session
        self.wsTask = task
        task.resume()

        status = .syncing
        notify()
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.handleDisconnect(reason: err.localizedDescription)
            case .success(let msg):
                self.handleMessage(msg)
                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .string(let text):
            if text == "ping" { return }   // 应用层心跳（仅 lx_music_mobile 客户端才会收到，本端一般收不到），忽略
            syncQueue.async { self.processInbound(text) }
        case .data(let d):
            // 极少数情况下服务端可能以二进制帧下发，按 UTF-8 文本解析
            if let text = String(data: d, encoding: .utf8) {
                syncQueue.async { self.processInbound(text) }
            }
        @unknown default:
            break
        }
        // 说明：服务端发来的 WebSocket ping 帧由 URLSession 自动回 pong，无需手动处理（.ping/.pong 用例为 iOS15+）
    }

    private func handleDisconnect(reason: String) {
        syncQueue.async { self.pending.removeAll() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if case .synced = self.status {
                // 已同步过，保持标记
            } else {
                self.status = .disconnected
            }
            self.notify()
        }
        Logger.error("LX 同步连接断开：\(reason)")
    }

    // MARK: - 报文处理

    private func processInbound(_ text: String) {
        let jsonString = LXSyncCrypto.decodeData(text)
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.error("LX 消息解析失败"); return
        }
        // message2call：有非空 path 是被调（CALL），否则是对本端调用的响应（RESPONSE）
        if let path = obj["path"] as? [String], !path.isEmpty {
            handleCall(obj, path: path)
        } else {
            handleResponse(obj)
        }
    }

    private func handleCall(_ obj: [String: Any], path: [String]) {
        guard let name = obj["name"] as? String,
              let fnName = path.last else { return }
        let args = obj["data"] as? [Any] ?? []
        guard let handler = handlers[fnName] else {
            respondError(name: name, message: "unknown function: \(fnName)")
            return
        }
        handler(args) { [weak self] result in
            switch result {
            case .success(let value): self?.respond(name: name, data: value)
            case .failure(let err):  self?.respondError(name: name, message: err.localizedDescription)
            }
        }
    }

    private func handleResponse(_ obj: [String: Any]) {
        guard let name = obj["name"] as? String else { return }
        let errorVal = obj["error"]
        let data = obj["data"]
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard let cb = self.pending.removeValue(forKey: name) else { return }
            if let errStr = errorVal as? String, !errStr.isEmpty {
                cb(.failure(NSError(domain: "LXSync", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errStr])))
            } else {
                cb(.success(data))
            }
        }
    }

    // MARK: - 发送

    private func respond(name: String, data: Any?) {
        var msg: [String: Any] = ["name": name, "error": NSNull()]
        msg["data"] = data ?? NSNull()
        send(obj: msg)
    }

    private func respondError(name: String, message: String) {
        send(obj: ["name": name, "error": message])
    }

    private func send(obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else {
            Logger.error("LX 发送报文序列化失败"); return
        }
        let frame = LXSyncCrypto.encodeData(json)
        wsTask?.send(.string(frame)) { [weak self] error in
            if let error = error { Logger.error("LX 发送失败：\(error.localizedDescription)") }
        }
    }

    /// 本端主动调用服务端函数（预留：实时把手机端变更推送到桌面端）
    func callServer(function: String, arguments: [Any], completion: @escaping (Result<Any?, Error>) -> Void) {
        let name = "\(function).__\(UUID().uuidString)"
        syncQueue.async { self.pending[name] = completion }
        send(obj: ["name": name, "path": [function], "data": arguments])
    }

    // MARK: - 被调函数注册（服务端会调用这些）

    private func registerHandlers() {
        handlers["getEnabledFeatures"] = { _, completion in
            // 我们支持 list 同步；dislike 暂不支持
            completion(.success(["list": ["skipSnapshot": false]]))
        }
        handlers["list_sync_get_list_data"] = { [weak self] _, completion in
            guard let self = self else { completion(.success(NSNull())); return }
            let data = LXSyncModels.getLocalListData()
            completion(.success(self.encodableToAny(data) ?? NSNull()))
        }
        handlers["list_sync_get_md5"] = { _, completion in
            completion(.success(LXSyncModels.localListDataMD5()))
        }
        handlers["list_sync_get_sync_mode"] = { _, completion in
            completion(.success(ConfigStore.shared.lxSyncMode))
        }
        handlers["list_sync_set_list_data"] = { [weak self] args, completion in
            if let any = args.first, let strongSelf = self,
               let ld: LXListData = strongSelf.decodeCodable(any) {
                LXSyncModels.applyRemoteListData(ld)
            } else {
                Logger.error("LX set_list_data 解码失败")
            }
            completion(.success(NSNull()))
        }
        handlers["onListSyncAction"] = { args, completion in
            if let any = args.first as? [String: Any],
               let action = any["action"] as? String {
                let inner = any["data"]
                LXSyncModels.applyAction(LXListAction(action: action, data: inner))
            }
            completion(.success(NSNull()))
        }
        handlers["list_sync_finished"] = { [weak self] _, completion in
            self?.markSynced()
            completion(.success(NSNull()))
        }
        handlers["finished"] = { [weak self] _, completion in
            self?.markSynced()
            completion(.success(NSNull()))
        }
    }

    private func markSynced() {
        didSync = true
        ConfigStore.shared.lxLastSyncDate = Date()
        let count = PlaylistStore.shared.playlists.count
        DispatchQueue.main.async { [weak self] in
            self?.status = .synced(playlistCount: count)
            self?.notify()
        }
    }

    // MARK: - Codable <-> [String: Any] 桥接

    private func encodableToAny<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any
    }

    private func decodeCodable<T: Decodable>(_ any: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: any),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        return v
    }

    // MARK: - 兼容旧版：/hello 测试

    /// 测试 HTTP 握手 — 桌面版 LX 响应 `Hello~::^-^::~v4~`
    func testConnection() {
        let raw = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            status = .notConfigured
            notify()
            return
        }
        let normalized = normalizeServerURL(raw)
        guard let req = makeRequest(urlString: normalized, extraPath: "/hello") else {
            status = .failed(reason: "URL 不合法（需 http/https 开头）")
            notify()
            return
        }
        status = .testing
        notify()
        let start = Date()
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.status = .failed(reason: "网络错误：\(error.localizedDescription)")
                    self.notify()
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.status = .failed(reason: "无响应")
                    self.notify()
                    return
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if http.statusCode == 200, body.localizedCaseInsensitiveContains("Hello") {
                    self.status = .ok(handshake: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                      latencyMs: ms)
                } else if http.statusCode == 404 {
                    self.status = .failed(reason: "HTTP 404 — 地址不是 LX 同步服务（\(normalized)）")
                } else {
                    self.status = .failed(reason: "HTTP \(http.statusCode)（\(normalized)）")
                }
                self.notify()
            }
        }.resume()
    }

    func probe(path: String, completion: @escaping (Result<String, Error>) -> Void) {
        let raw = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeServerURL(raw)
        guard let req = makeRequest(urlString: normalized, extraPath: path) else {
            completion(.failure(NSError(domain: "LXSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL 不合法"])))
            return
        }
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let e = error { completion(.failure(e)); return }
                completion(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
            }
        }.resume()
    }

    // MARK: - Helpers

    private func notify() {
        // 状态变化会驱动 UI 刷新（LXSyncViewController.lxStateChanged），
        // 而本服务大量回调来自 URLSession / syncQueue 后台线程，
        // 必须回到主线程 post，否则观察者会在后台线程触碰布局引擎导致崩溃。
        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: self)
        }
    }

    /// 接受 `192.168.1.5:23332`/`example.com/lxsync`/`http://...` 等多种写法
    /// 统一归一为 `http(s)://host[:port][/path]` 不带末尾 /
    private func normalizeServerURL(_ raw: String) -> String {
        var s = raw
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func makeRequest(urlString: String, extraPath: String) -> URLRequest? {
        let sep = extraPath.hasPrefix("/") ? "" : "/"
        guard let url = URL(string: urlString + sep + extraPath) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("MoshouMusic-iOS/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }
}
