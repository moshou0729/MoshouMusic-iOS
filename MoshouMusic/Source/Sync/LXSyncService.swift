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

    // WebSocket 相关（v1.0.55：用自实现 LXWebSocketClient 替代 URLSessionWebSocketTask）
    private var wsClient: LXWebSocketClient?
    /// WS 握手失败自动重试相关（v1.0.51）：服务端在 /ah 返回后才 saveClientKeyInfo，
    /// 若那步是异步的，紧跟着建 WS 会 getClientKeyInfo 取不到 → 401。
    private var wsRetryCount = 0
    private var lastHostPath: String?
    private var lastKeyInfo: LXClientKeyInfo?
    /// 保存 percent-encode 后的 t（用于 v1.0.52 诊断输出 + 让用户用真实 i/t 在电脑 curl 测）
    private var lastTEnc: String?
    private var userDidStop = false

    // 同步专用 HTTP 会话：独立 ephemeral 配置，避免与音乐搜索等共享 URLSession 的连接池互相挤占；
    // 并显式关闭 waitsForConnectivity，防止系统把局域网请求误判为“等待联网”而静默挂起。
    private lazy var syncHTTPSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // 20s → 30s：与 /ah 的 req.timeoutInterval 一致，
        // 否则 session 级会先于 request 级超时截断
        cfg.timeoutIntervalForRequest = 30
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
        // 重置 WS 重试状态（stopSync 会把 userDidStop 置 true，这里要清掉）
        userDidStop = false
        wsRetryCount = 0
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
                                let hint: String
                                if isCodeProblem {
                                    hint = "\(desc)（同步码可能已过期，请立即在桌面端 LX Music 上重新生成后输入）"
                                } else {
                                    // 能走到这一步说明 /hello 与 /id 都已成功 —— 手机到桌面的 HTTP 是通的，
                                    // 只有 /ah 认证不响应，基本是桌面端同步服务本身没真正启动。
                                    hint = "\(desc)\n\n注意：/hello 与 /id 都成功了，说明手机到桌面的网络是通的，只有 /ah 无响应。\n通常意味着桌面端同步服务没真正启动。请：\n① 完全退出并重启桌面端 LX Music；\n② 确认「设置 → 同步 → 服务端模式」已开启且显示服务已启动；\n③ 临时关闭电脑防火墙 / 第三方安全软件后重试。"
                                }
                                self.status = .failed(reason: "认证失败：\(hint)"); self.currentStep = nil; self.notify()
                            case .success(let keyInfo):
                                // 服务端在 /ah 响应之后才 saveClientKeyInfo（可能是异步的）。
                                // 立刻建 WS 时 getClientKeyInfo(clientId) 可能还没存好 → 401。
                                // 延迟 0.8s 再建连，并配合 handleDisconnect 的自动重试兜底。
                                self.currentStep = "认证成功，正在建立 WebSocket 连接…"
                                self.notify()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                                    self?.connectWebSocket(hostPath: hostPath, keyInfo: keyInfo)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 停止同步并关闭 WebSocket
    func stopSync() {
        userDidStop = true   // 用户主动停止，不再自动重试
        wsClient?.close()
        wsClient = nil
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
        // 对齐 server/auth.ts 的 verifyByCode：
        //   text.split('\n') -> [0]=authMsg [1]=公钥base64 [2]=设备名 [3]=客户端类型
        //   isMobile = (data[3] == 'lx_music_mobile')
        // 我们是手机端，标 lx_music_mobile，让服务端按移动端处理（会下发应用层 'ping'，
        // handleMessage 里已忽略该文本帧）。
        let plaintext = "lx-music auth::\n\(pubB64)\n\(deviceName)\nlx_music_mobile"
        let m = LXSyncCrypto.aesEncryptLX(plaintext: plaintext, keyBase64: aesKey)
        guard !m.isEmpty else {
            completion(.failure(NSError(domain: "LXSync", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "认证报文加密失败"]))); return
        }

        var req = URLRequest(url: URL(string: "\(hostPath)/ah")!)
        req.httpMethod = "GET"
        // 12s（之前 20s）—— F6：便于更早反馈失败，但桌面 AES + RSA 解密仍有足够余量
        // 12s → 30s：桌面端要做 RSA 解密，慢机器/首次连接可能要更久
        req.timeoutInterval = 30
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
        // 记住参数，供握手失败自动重试使用
        self.lastHostPath = hostPath
        self.lastKeyInfo = keyInfo

        let wsURLString = hostPath
            .replacingOccurrences(of: "http", with: "ws", options: [.anchored])
            + "/socket"
        let t = LXSyncCrypto.aesEncryptLX(plaintext: "lx-music connect", keyBase64: keyInfo.key)
        // ⚠️ 必须用 RFC 3986 unreserved 字符集（不含 '+' '/' '=' '&' '?'），
        // 不能用 .urlQueryAllowed —— 那个集合**包含 '+'**，不会 percent-encode。
        // base64 密文常含 '+' '/' '='；Node 的 querystring.parse 会把 '+' 解码成空格，
        // base64 就会被破坏，服务端 AES 解密必然失败 → /socket 升级被 401 + destroy。
        // v1.0.47 的 "连接已断开 + 拉取中" 就是这个原因。
        let safeChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let i = keyInfo.clientId.addingPercentEncoding(withAllowedCharacters: safeChars),
              let tEnc = t.addingPercentEncoding(withAllowedCharacters: safeChars),
              let url = URL(string: "\(wsURLString)?i=\(i)&t=\(tEnc)") else {
            status = .failed(reason: "构造 WebSocket 地址失败"); notify(); return
        }
        // 记住 percent-encoded t（v1.0.52：失败时显示给用户便于电脑 curl 复现）
        self.lastTEnc = tEnc

        // v1.0.55：用自实现 LXWebSocketClient 替代 URLSessionWebSocketTask。
        // iOS 14.7.1 的 URLSessionWebSocketTask 在收到 LX 桌面端 ws 库的 101
        // 响应后拒绝完成握手（即使 Sec-WebSocket-Accept 正确），报 "Socket is not connected"。
        // v1.0.54 已用 dataTask 模拟 upgrade 拿到 HTTP 101 + 全部正确 headers，
        // 确诊为 iOS 端 URLSessionWebSocketTask 与 ws 库握手兼容性问题。
        // LXWebSocketClient 用 URLSessionStreamTask 拿 TCP 字节流自己完成 RFC 6455 握手与帧收发。
        let client = LXWebSocketClient(url: url)
        client.onOpen = { [weak self] in
            guard let self = self else { return }
            Logger.info("LX WS handshake ok")
            self.status = .syncing
            // v1.0.58：这里**不再**主动调 list_sync_get_md5 —— 方向是反的。
            // 桌面端 callObj 只暴露 onListSyncAction 给客户端调用；
            // list_sync_get_md5 / list_sync_get_list_data / list_sync_set_list_data /
            // list_sync_finished 全都是**服务端调用客户端**的函数（见
            // server/modules/list/sync/handler.ts 与 sync/sync.ts）。
            // 同步由桌面端主动编排：getEnabledFeatures → list_sync_get_list_data
            // →（需要时桌面端弹窗让用户选合并/覆盖方式）→ list_sync_set_list_data
            // → list_sync_finished。本端只需正确响应这些调用（见 registerHandlers）。
            self.currentStep = "已连接桌面端，等待桌面端下发歌单…\n若桌面端弹出「选择同步方式」，请选一种并确定"
            self.notify()
        }
        client.onText = { [weak self] text in
            self?.syncQueue.async { self?.processInbound(text) }
        }
        client.onClose = { [weak self] code, reason in
            self?.handleDisconnect(reason: "close code=\(code ?? -1) reason=\(reason ?? "?")")
        }
        client.onError = { [weak self] err in
            let why: String
            if let e = err as? LXWebSocketClient.WSError {
                why = "\(e)"
            } else {
                why = err.localizedDescription
            }
            self?.handleDisconnect(reason: "WS: \(why)")
        }
        self.wsClient = client
        client.connect()
    }

    // MARK: - 主动同步    }

    // MARK: - 主动同步

    private func handleDisconnect(reason: String) {
        syncQueue.async { self.pending.removeAll() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if case .synced = self.status {
                // 已同步过，保持标记
                self.currentStep = nil
                self.notify()
                return
            }
            // v1.0.51：WS 握手失败自动重试。
            // 服务端在 /ah 返回之后才 saveClientKeyInfo，若那步是异步的，
            // 紧跟在 /ah 后面建 WS 会 getClientKeyInfo(clientId) 取不到 → 401。
            // 实测 curl 用假 i/t 会稳定回 401（服务端 upgrade handler 工作正常），
            // 所以真实凭证被拒更可能是时序问题而不是凭证本身错。
            if !self.userDidStop, self.wsRetryCount < 2,
               let host = self.lastHostPath, let ki = self.lastKeyInfo {
                self.wsRetryCount += 1
                let n = self.wsRetryCount
                let delay = Double(n) * 1.5
                self.status = .syncing
                self.currentStep = "第 \(n) 次连接失败，\(Int(delay)) 秒后重试…"
                self.notify()
                Logger.error("LX WS retry #\(n) reason=\(reason)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.userDidStop else { return }
                    self.connectWebSocket(hostPath: host, keyInfo: ki)
                }
                return
            }
            // 重试耗尽：把失败原因显示在状态文字里（.disconnected 没有 reason 字段），
            // 并把真实 i 和 t 一并输出 —— 用户截图发我，我就能直接在电脑用真实凭证 curl
            // 服务端的 /socket upgrade，从而一锤定音是服务端拒绝还是 iOS URLSession 握手 bug。
            var diag = "WebSocket 升级失败（已重试 2 次）：\(reason)。"
            if let ki = self.lastKeyInfo {
                diag += "  i=\(ki.clientId)"
                if let t = self.lastTEnc { diag += "  t=\(t)" }
            }
            self.status = .failed(reason: diag)
            self.currentStep = nil
            self.notify()
        }
        Logger.error("LX 同步连接断开：\(reason)")
    }

// MARK: - 报文处理

    /// v1.0.58：message2call 收发的都是 **JSON 数组**，不是对象。
    /// 形如 [type, name, ...]，按 type 分派（0=被调用 / 1=我方调用的返回）。
    private func processInbound(_ text: String) {
        // 服务端对 isMobile 客户端会周期性发文本 'ping'，不是 message2call 报文
        guard text != "ping" else { wsClient?.send(text: "pong"); return }

        let jsonString = LXSyncCrypto.decodeData(text)
        guard let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3,
              let type = arr[0] as? Int,
              let name = arr[1] as? String else {
            Logger.error("LX 消息解析失败（非 message2call 数组）：\(text.prefix(120))"); return
        }
        switch type {
        case callTypeRequest:            // [0, name, path, args, callbacks] 服务端调用本端
            guard arr.count >= 4, let path = arr[2] as? [String] else { return }
            let args = arr[3] as? [Any] ?? []
            handleCall(name: name, path: path, args: args)
        case callTypeResponse:           // [1, name, null, data] 或 [1, name, {message}]
            // 有第 4 个元素且第 3 个为 null → 成功
            let err = arr[2] as? [String: Any]
            let result: Any? = arr.count >= 4 ? arr[3] : nil
            handleResponse(name: name, error: err, data: result)
        default:
            break                        // CALLBACK_REQUEST / CALLBACK_RESPONSE 暂未用到
        }
    }

    private func handleCall(name: String, path: [String], args: [Any]) {
        // local.handleRequest 语义：path.pop() 取最后一个作函数名，前面的是嵌套对象路径。
        // 服务端调的是 remoteQueueList.list_sync_get_md5()，path 形如 ["list_sync_get_md5"]。
        guard let fnName = path.last else { return }
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

    private func handleResponse(name: String, error: [String: Any]?, data: Any?) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard let cb = self.pending.removeValue(forKey: name) else { return }
            if let err = error, let msg = err["message"] as? String, !msg.isEmpty {
                cb(.failure(NSError(domain: "LXSync", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
            } else {
                cb(.success(data))
            }
        }
    }

    // MARK: - 发送

    // MARK: - message2call 线格式（v1.0.58 修正：数组，不是对象）
    //
    // ⚠️ 这是 v1.0.39～v1.0.57 一直卡在「已连上桌面端，但无法主动拉取歌单」的根本原因。
    // 服务端 m2c.message() 第一行就是 `if (!Array.isArray(message)) throw new Error('message is not array')`。
    // 我们之前发的是 `{"name":..,"path":..,"data":..}` **对象** → 服务端直接抛异常；而 server.ts
    // 的 message listener 在 catch 里**只打日志、不关 socket**，于是连接看着是通的却永远不响应
    // → 本端 callServer 超时，UI 显示「无法主动拉取歌单」。
    //
    // 正确格式（message2call/src/shared.ts、local.ts、remote.ts）：
    //   enum CALL_TYPES { REQUEST = 0, RESPONSE = 1, CALLBACK_REQUEST = 2, CALLBACK_RESPONSE = 3 }
    //   发起调用  [0, eventName, path: [String], args: [Any], callbacks: [Int]]
    //   返回结果  [1, eventName, null, data]   失败则 [1, eventName, {message, stack}]
    //
    // 另：group 名（'list'）**不进 path**（remote.ts 的 createProxy 只累积属性名），
    // 所以服务端 `remoteQueueList.list_sync_get_md5()` 的 path 就是 ["list_sync_get_md5"]。
    private let callTypeRequest: Int = 0
    private let callTypeResponse: Int = 1

    /// 成功响应：[1, name, null, data]
    private func respond(name: String, data: Any?) {
        sendArray([callTypeResponse, name, NSNull(), data ?? NSNull()])
    }

    /// 失败响应：[1, name, {message: ...}]
    private func respondError(name: String, message: String) {
        sendArray([callTypeResponse, name, ["message": message]])
    }

    private func sendArray(_ payload: [Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            Logger.error("LX 发送报文序列化失败"); return
        }
        let frame = LXSyncCrypto.encodeData(json)
        wsClient?.send(text: frame)
    }

    /// 本端主动调用服务端函数（预留：实时把手机端变更推送到桌面端）
    func callServer(function: String, arguments: [Any], timeout: TimeInterval = 20,
                    completion: @escaping (Result<Any?, Error>) -> Void) {
        let name = "\(function).__\(UUID().uuidString)"
        syncQueue.async { self.pending[name] = completion }
        // v1.0.58：message2call 是**数组**协议 → [0, name, path, args, callbacks]
        // 之前发的对象会被服务端 `Array.isArray` 判否直接丢弃。
        sendArray([callTypeRequest, name, [function], arguments, []])

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
                "请求超时：桌面同步服务 30 秒内无响应。请确认：①手机与桌面在同一局域网；②桌面端「同步 → 服务端模式」正在运行；③系统防火墙/杀毒放行同步端口（默认 9527）；④手机未开启会把局域网请求转到公网的 VPN/代理。"])
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
        // 与 authWithCode 保持一致：客户端类型标 lx_music_mobile（服务端据此判断 isMobile）
        let plaintext = "lx-music auth::\n\(pubB64)\n\(deviceName)\nlx_music_mobile"
        let m = LXSyncCrypto.aesEncryptLX(plaintext: plaintext, keyBase64: aesKey)
        var req = URLRequest(url: URL(string: "\(hostPath)/ah")!)
        req.httpMethod = "GET"
        // F6：12 秒（原来 20 秒）—— 给桌面 AES + RSA 解密留够余量，但卡住也能更快反馈
        // 12s → 30s：桌面端要做 RSA 解密，慢机器/首次连接可能要更久
        req.timeoutInterval = 30
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
