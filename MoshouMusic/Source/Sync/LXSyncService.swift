import Foundation
import UIKit
import Security
import Network

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
    /// 当前阶段文字（用于 UI 在 .connecting 期间显示具体进度，
    /// 避免「正在认证」一闪而过就变 .failed 而让用户以为没反应）
    private(set) var currentStep: String?

    static let stateChangedNotification = Notification.Name("LXSyncStateChanged")

    // WebSocket 相关
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?

    // 同步专用 HTTP 会话：独立 ephemeral 配置，避免与音乐搜索等共享 URLSession 的连接池互相挤占；
    // 并显式关闭 waitsForConnectivity，防止系统把局域网请求误判为“等待联网”而静默挂起。
    private lazy var syncHTTPSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: cfg)
    }()

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
            status = .failed(reason: "请输入桌面端显示的 6 位同步码"); currentStep = nil; notify(); return
        }
        guard let hostPath = hostPathFromConfig() else {
            status = .failed(reason: "请先在上方填写同步服务地址"); currentStep = nil; notify(); return
        }
        didSync = false
        status = .connecting
        currentStep = "正在 /hello 握手…"
        notify()

        getHello(hostPath) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.status = .failed(reason: "握手失败：\(e.localizedDescription)"); self.currentStep = nil; self.notify()
            case .success:
                self.currentStep = "正在 /id 验证服务端…"
                self.notify()
                self.getServerId(hostPath) { serverIdResult in
                    switch serverIdResult {
                    case .failure(let e):
                        self.status = .failed(reason: "获取服务 ID 失败：\(e.localizedDescription)"); self.currentStep = nil; self.notify()
                    case .success:
                        self.currentStep = "正在 /ah 认证（请确保桌面码 60 秒内有效，最长 20 秒）"
                        self.notify()
                        guard let (pub, priv) = LXSyncCrypto.generateRSAKeyPair() else {
                            self.status = .failed(reason: "RSA 密钥生成失败"); self.currentStep = nil; self.notify(); return
                        }
                        self.authWithCode(hostPath: hostPath, authCode: code,
                                         publicPEM: pub, privateKey: priv) { authResult in
                            switch authResult {
                            case .failure(let e):
                                let desc = e.localizedDescription
                                // 只在明确是「码错误」类失败时才追加码过期提示；
                                // 网络/防火墙超时（-1001 之类）不要再误导用户「码可能过期」
                                let isCodeProblem = desc.contains("同步码") || desc.contains("Auth failed") || desc.contains("auth")
                                let hint = isCodeProblem
                                    ? "\(desc)（同步码可能已过期，请立即在桌面端 LX Music 上重新生成后输入）"
                                    : desc
                                self.status = .failed(reason: "认证失败：\(hint)"); self.currentStep = nil; self.notify()
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
        req.httpMethod = "GET"
        // 12s（之前 20s）—— F6：便于更早反馈失败，但桌面 AES + RSA 解密仍有足够余量
        // 12s → 20s：留足桌面端 RSA + AES 解密时间，避免局域网慢时 401 与超时分不清
        req.timeoutInterval = 20
        req.setValue(m, forHTTPHeaderField: "m")
        syncHTTPSession.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(self.classify(error))); return }
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
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        syncHTTPSession.dataTask(with: req) { data, _, error in
            if let error = error { completion(.failure(self.classify(error))); return }
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
        currentStep = "正在拉取桌面端歌单…"
        notify()
        receiveLoop()

        // 主动发起一次同步。
        // 原实现接入 WebSocket 后只是被动等桌面端调用本端 handler，桌面端若不主动发起，
        // 本端就一直停在 .syncing —— 用户看到的就是「点了同步没反应」。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.performActiveSync()
        }
    }

    // MARK: - 主动同步

    /// 连上后主动向桌面端拉取歌单：先比 MD5，不同再拉全量并落地。
    private func performActiveSync() {
        guard case .syncing = status else { return }

        callServer(function: "list_sync_get_md5", arguments: [], timeout: 12) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 桌面端不接受本端主动调用 → 明确告知，而不是无限等待
                self.status = .failed(reason: "已连上桌面端，但无法主动拉取歌单。请确认桌面端「同步」已开启，并在桌面端 LX Music 上点一次同步。")
                self.currentStep = nil
                self.notify()
            case .success(let any):
                let remoteMD5 = (any as? String) ?? ""
                let localMD5 = LXSyncModels.localListDataMD5()
                if !remoteMD5.isEmpty && remoteMD5 == localMD5 {
                    self.didSync = true
                    self.status = .synced(playlistCount: PlaylistStore.shared.playlists.count)
                    self.currentStep = nil
                    self.notify()
                    return
                }
                self.currentStep = "MD5 不同，正在拉取完整歌单数据…"
                self.notify()
                self.pullRemoteListData()
            }
        }
    }

    /// 拉取桌面端的完整歌单数据并写入本地
    private func pullRemoteListData() {
        callServer(function: "list_sync_get_list_data", arguments: [], timeout: 25) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.status = .failed(reason: "拉取桌面歌单失败：\(e.localizedDescription)")
                self.currentStep = nil
                self.notify()
            case .success(let any):
                guard let ld: LXListData = self.decodeCodable(any) else {
                    self.status = .failed(reason: "桌面歌单数据解析失败")
                    self.notify()
                    return
                }
                // 写库必须在主线程（PlaylistStore 不是线程安全的）
                DispatchQueue.main.async {
                    LXSyncModels.applyRemoteListData(ld)
                    self.didSync = true
                    self.status = .synced(playlistCount: PlaylistStore.shared.playlists.count)
                    self.currentStep = nil
                    self.notify()
                }
            }
        }
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
    func callServer(function: String, arguments: [Any], timeout: TimeInterval = 20,
                    completion: @escaping (Result<Any?, Error>) -> Void) {
        let name = "\(function).__\(UUID().uuidString)"
        syncQueue.async { self.pending[name] = completion }
        send(obj: ["name": name, "path": [function], "data": arguments])

        // 超时兜底：桌面端若不响应该调用，pending 会一直挂着，UI 就永远得不到反馈
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            self.syncQueue.async {
                guard let cb = self.pending.removeValue(forKey: name) else { return }
                DispatchQueue.main.async {
                    cb(.failure(NSError(domain: "LXSync", code: 408,
                        userInfo: [NSLocalizedDescriptionKey: "\(function) 超时（\(Int(timeout)) 秒无响应）"])))
                }
            }
        }
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
                // 写库与状态更新回到主线程：本 handler 跑在 syncQueue 上，
                // 而 PlaylistStore 不是线程安全的
                DispatchQueue.main.async {
                    LXSyncModels.applyRemoteListData(ld)
                    strongSelf.didSync = true
                    strongSelf.status = .synced(playlistCount: PlaylistStore.shared.playlists.count)
                    strongSelf.currentStep = nil
                    strongSelf.notify()
                }
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
        // 兜底：URLSession 在 iOS 14 上偶发对局域网 IP 不回调，强加 25s 强制超时
        // 避免界面永远卡在「正在测试…」
        let forceTimeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .testing = self.status {
                self.status = .failed(reason: "请求超时（25 秒内桌面端未响应 /hello）。\n请确认：\n①手机与桌面在同一局域网\n②桌面端「同步 → 服务端模式」已开启\n③系统防火墙/杀毒放行同步端口（默认 23332）\n④手机未开 VPN/代理把局域网请求转公网")
                self.notify()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: forceTimeout)
        syncHTTPSession.dataTask(with: req) { [weak self] data, response, error in
            forceTimeout.cancel()
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
        syncHTTPSession.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let e = error { completion(.failure(self.classify(e))); return }
                completion(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
            }
        }.resume()
    }

    // MARK: - Helpers

    /// 把底层 URLSession 错误翻译成对用户友好的中文说明，便于区分
    /// “服务器不响应（网络/防火墙）” 与 “响应了但认证失败（同步码/协议）”。
    private func classify(_ error: Error) -> Error {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return error }
        switch e.code {
        case NSURLErrorTimedOut:
            return NSError(domain: "LXSync", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "请求超时：桌面同步服务 20 秒内无响应。几乎都是网络/防火墙问题——请确认：①手机与桌面在同一局域网；②桌面端「同步 → 服务端模式」正在运行；③系统防火墙/杀毒放行同步端口（默认 9527）；④手机未开启会把局域网请求转到公网的 VPN/代理。"])
        case NSURLErrorCannotConnectToHost:
            return NSError(domain: "LXSync", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "无法连接桌面同步服务（连接被拒绝/主机不可达）。请确认桌面端同步服务正在运行且地址端口正确。"])
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return NSError(domain: "LXSync", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "网络连接中断或离线。请确认手机网络正常且与桌面在同一局域网。"])
        default:
            return error
        }
    }

    /// 诊断：用用户实际输入的同步码做真实 /ah 认证，并把链路各步结果原样返回。
    ///
    /// 旧版故意发送非法 `m="__probe_invalid__"`，导致**永远返回 401**，用户即便码正确也看到 401。
    /// 现在与 `startSync` 走同一套加密流程（AES-128-ECB(keyFromAuthCode(code)) 加密
    /// `lx-music auth::\n<pub>\n<deviceName>\nlx_music_desktop`），因此 401 现在**真实代表「同步码错误或已失效」**，
    /// 而不再是诊断按钮自身的假错误。
    ///
    /// F6：诊断开始前先用 Network framework 做一次 TCP 端口可达性探测，
    /// 端口不可达立即报错（不再让用户以为是同步码错误）；`/ah` 超时缩短到 12 秒以便更快反馈。
    func probeAH(authCode: String, completion: @escaping (String) -> Void) {
        guard let hostPath = hostPathFromConfig() else {
            completion("未配置同步服务地址（请先在上方填写并保存）。"); return
        }
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            completion("请先在「同步码」框输入桌面端显示的 6 位同步码，再点诊断。"); return
        }

        var report = "诊断目标：\(hostPath)\n同步码：\(code)\n\n"

        // ① 先做一次 TCP 端口可达性探测（如不可达直接返回，节省 /hello 12s+ 等待）
        if let (host, port) = parseHostPort(hostPath) {
            report += "预检：正在 TCP 探测 \(host):\(port)…\n\n"
            let probeResult = probeTCP(host: host, port: port, timeout: 3.0)
            switch probeResult {
            case .reachable:
                report += "预检：✓ TCP \(host):\(port) 可达\n\n"
            case .unreachable(let reason):
                report += "预检：✗ TCP \(host):\(port) 不可达（\(reason)）\n\n"
                report += "结论：手机连不上桌面 \(host):\(port)。几乎都是网络/防火墙问题：\n" +
                          "①手机与桌面在同一局域网\n" +
                          "②桌面端「同步 → 服务端模式」正在运行\n" +
                          "③系统防火墙/杀毒放行同步端口\n" +
                          "④手机未开会把局域网请求转公网的 VPN/代理\n" +
                          "这是网络问题，不是同步码问题，请先排查网络。"
                completion(report); return
            case .timedOut:
                report += "预检：✗ TCP \(host):\(port) 3 秒内无响应（连接被防火墙丢弃/超时）\n\n"
                report += "结论：网络层 3 秒内无任何响应，桌面端口被屏蔽或地址不可达。\n" +
                          "请确认桌面同步服务已启动且手机与桌面在同一局域网，并检查系统防火墙。"
                completion(report); return
            }
        }

        var steps: [String] = []
        let group = DispatchGroup()
        var helloOk = false
        var idOk = false

        group.enter()
        getHello(hostPath) { result in
            switch result {
            case .success: helloOk = true; steps.append("① /hello：✓ 握手正常")
            case .failure(let e): steps.append("① /hello：✗ \(e.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        getServerId(hostPath) { result in
            switch result {
            case .success: idOk = true; steps.append("② /id：✓ 服务 ID 正常")
            case .failure(let e): steps.append("② /id：✗ \(e.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        guard let (pub, priv) = LXSyncCrypto.generateRSAKeyPair() else {
            steps.append("③ /ah：✗ 本地 RSA 密钥生成失败")
            group.leave(); return
        }
        let aesKey = LXSyncCrypto.keyFromAuthCode(code)
        let pubB64 = pub
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let deviceName = UIDevice.current.name
        let plaintext = "lx-music auth::\n\(pubB64)\n\(deviceName)\nlx_music_desktop"
        let m = LXSyncCrypto.aesEncryptLX(plaintext: plaintext, keyBase64: aesKey)
        var req = URLRequest(url: URL(string: "\(hostPath)/ah")!)
        req.httpMethod = "GET"
        // F6：12 秒（原来 20 秒）—— 给桌面 AES + RSA 解密留够余量，但卡住也能更快反馈
        // 12s → 20s：留足桌面端 RSA + AES 解密时间，避免局域网慢时 401 与超时分不清
        req.timeoutInterval = 20
        req.setValue(m, forHTTPHeaderField: "m")
        syncHTTPSession.dataTask(with: req) { data, response, error in
            defer { group.leave() }
            if let error = error {
                let e = error as NSError
                steps.append("③ /ah：✗ 网络错误（\(e.localizedDescription)，domain=\(e.domain) code=\(e.code)）")
                return
            }
            let http = response as? HTTPURLResponse
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let status = http?.statusCode ?? -1
            if status == 200 {
                steps.append("③ /ah：✓ HTTP 200，同步码有效，认证通过。")
            } else if body.contains("Blocked") {
                steps.append("③ /ah：✗ HTTP \(status) — IP 被封禁（请求过于频繁，稍后重试）。")
            } else if body.contains("Auth failed") || status == 401 {
                steps.append("③ /ah：✗ HTTP \(status) — 同步码错误或已失效（桌面端码每 60 秒轮换，请确保在有效期内使用）。")
            } else {
                steps.append("③ /ah：✗ HTTP \(status) — 响应体：\(body.isEmpty ? "(空)" : body)")
            }
        }.resume()

        group.notify(queue: .main) {
            var summary = report + steps.joined(separator: "\n") + "\n\n"
            if helloOk && idOk && steps.contains(where: { $0.hasPrefix("③ /ah：✓") }) {
                summary += "结论：链路正常，同步码有效。若实际同步仍失败，请确认桌面端「同步」服务在同步期间保持运行，且未开启会把局域网请求转公网的 VPN/代理。"
            } else if !helloOk {
                summary += "结论：手机连不上桌面同步服务（/hello 失败），几乎都是网络/防火墙问题——确认同一局域网、桌面端同步服务运行、端口放行、关闭 VPN/代理。"
            } else if helloOk && idOk {
                summary += "结论：握手与 ID 正常，但 /ah 认证未过。请重新点桌面端的「生成同步码」拿到最新 6 位码，并在 60 秒有效期内完成同步/诊断。"
            }
            completion(summary)
        }
    }

    // MARK: - TCP 端口可达性探测（F6 新增）

    private enum TCPProbeResult {
        case reachable
        case unreachable(String)   // 显式拒绝（如 Connection refused）
        case timedOut               // 黑洞（防火墙丢包）
    }

    /// 用 Network framework 做一次 TCP 连接探测，超时立即结束不挂 UI
    private func probeTCP(host: String, port: UInt16, timeout: TimeInterval) -> TCPProbeResult {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 9527
        let conn = NWConnection(host: endpoint, port: nwPort, using: .tcp)

        let semaphore = DispatchSemaphore(value: 0)
        var result: TCPProbeResult = .timedOut

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result = .reachable
                conn.cancel()
                semaphore.signal()
            case .failed(let err):
                let code = (err as NSError).code
                result = .unreachable(err.localizedDescription + " (NWError code=\(code))")
                conn.cancel()
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "com.moshou.lxtcpprobe"))
        // 限时等待，避免永远阻塞
        _ = semaphore.wait(timeout: .now() + timeout)
        if conn.state != .cancelled { conn.cancel() }
        return result
    }

    /// 从 `http://192.168.3.2:12345` 或 `192.168.1.5:23332` 解析出 host + port
    private func parseHostPort(_ hostPath: String) -> (host: String, port: UInt16)? {
        // 去掉协议头与路径
        var s = hostPath
        if let r = s.range(of: "://") { s.removeSubrange(s.startIndex..<r.upperBound) }
        if let r = s.range(of: "/") { s = String(s[..<r.lowerBound]) }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port: UInt16
        if parts.count >= 2, let p = UInt16(parts[1]) {
            port = p
        } else {
            port = 9527
        }
        return (host, port)
    }

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
        req.timeoutInterval = 20
        req.setValue("MoshouMusic-iOS/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }
}
