import Foundation

/// LX Music 桌面版同步服务客户端
/// 当前仅实现 HTTP 握手验证 (/hello)
/// 完整的 WebSocket + message2call RPC + 加密 双向同步将在 v1.0.16+ 上线
final class LXSyncService {

    /// 同步连接状态机
    enum Status: Equatable {
        case notConfigured           // 未填写服务地址
        case idle                    // 已配置但未测试
        case testing                 // 正在请求 /hello
        case ok(handshake: String, latencyMs: Int)   // 握手成功
        case failed(reason: String)  // 失败（含错误原因）

        var displayText: String {
            switch self {
            case .notConfigured:        return "未配置"
            case .idle:                 return "已配置，未连接"
            case .testing:              return "正在测试…"
            case .ok(let h, let ms):    return "✓ 已连接（\(ms)ms）\n服务器：\(h.prefix(60))"
            case .failed(let r):        return "✗ \(r)"
            }
        }

        var isConnected: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    static let shared = LXSyncService()

    private(set) var status: Status = .notConfigured

    static let stateChangedNotification = Notification.Name("LXSyncStateChanged")

    private init() {
        refreshInitialState()
    }

    /// 启动时根据已保存的 URL 初始化状态文字
    func refreshInitialState() {
        let url = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            status = .notConfigured
        } else {
            status = .idle
        }
    }

    /// 测试 HTTP 握手 — 桌面版 LX 响应 `Hello~::^-^::~v3~`
    func testConnection() {
        let raw = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            status = .notConfigured
            notify()
            return
        }

        // 容错：自动补 scheme、剥尾斜杠、补 /hello
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
                if http.statusCode == 200,
                   body.localizedCaseInsensitiveContains("Hello") {
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

    /// 探测指定路径（用于「连接 LX 桌面端管理页之类」的扩展）
    /// 当前保留为 v1.0.16+ 的服务端校验接口
    func probe(path: String, completion: @escaping (Result<String, Error>) -> Void) {
        let raw = ConfigStore.shared.lxSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeServerURL(raw)
        guard let req = makeRequest(urlString: normalized, extraPath: path) else {
            completion(.failure(NSError(domain: "LXSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL 不合法"])))
            return
        }
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let e = error {
                    completion(.failure(e))
                    return
                }
                completion(.success(String(data: data ?? Data(), encoding: .utf8) ?? ""))
            }
        }.resume()
    }

    // MARK: - Helpers

    private func notify() {
        NotificationCenter.default.post(name: Self.stateChangedNotification, object: self)
    }

    /// 接受 `192.168.1.5:23332`/`example.com/lxsync`/`http://...` 等多种写法
    /// 统一归一为 `http(s)://host[:port][/path]` 不带末尾 /
    private func normalizeServerURL(_ raw: String) -> String {
        var s = raw
        // 缺 scheme 时默认 http（LAN 同步服务典型是 http）
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        // 剥末尾斜杠
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }

    private func makeRequest(urlString: String, extraPath: String) -> URLRequest? {
        let sep = extraPath.hasPrefix("/") ? "" : "/"
        guard let url = URL(string: urlString + sep + extraPath) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 14_7 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("MoshouMusic-iOS/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }
}
