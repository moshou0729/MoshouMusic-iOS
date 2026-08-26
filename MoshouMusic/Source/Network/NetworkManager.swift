import Foundation

/// 网络响应
struct NetworkResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String
    let rawData: Data?
    /// 跟随重定向后的最终地址（短链解析用）
    let finalURL: String?
}

/// 阻止自动重定向的 delegate — 让脚本能读到 302 的 Location 头
/// 咪咕等平台的播放接口正是靠 302 返回真实直链
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // 不跟随，把 302 原样交回
    }
}

/// 网络请求管理器 — 供 ScriptEngine 的 lx.request 桥接使用
/// 支持自定义 Headers、Body、超时、二进制响应，以及「不跟随重定向」
class NetworkManager {

    static let shared = NetworkManager()

    private let session: URLSession
    /// 不跟随重定向的会话（用于取 302 Location）
    private let noRedirectSession: URLSession
    private let noRedirectDelegate = NoRedirectDelegate()
    private let defaultTimeout: TimeInterval = 30

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        session = URLSession(configuration: config)

        let nrConfig = URLSessionConfiguration.default
        nrConfig.timeoutIntervalForRequest = 30
        nrConfig.timeoutIntervalForResource = 60
        nrConfig.httpAdditionalHeaders = config.httpAdditionalHeaders
        noRedirectSession = URLSession(
            configuration: nrConfig,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - 请求

    func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil,
        timeout: Double = 30,
        isBinary: Bool = false,
        followRedirect: Bool = true,
        completion: @escaping (Result<NetworkResponse, Error>) -> Void
    ) {
        guard let requestUrl = URL(string: url) else {
            completion(.failure(NSError(
                domain: "NetworkManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]
            )))
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = min(timeout, 120)

        // Headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body
        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        Logger.debug("[NET] \(method) \(url)")

        let activeSession = followRedirect ? session : noRedirectSession
        let task = activeSession.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.error("[NET] Error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(
                    domain: "NetworkManager",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
                )))
                return
            }

            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    responseHeaders[key] = value
                    // 同时存一份全小写 key，方便 JS 脚本大小写不敏感取值（如 location）
                    responseHeaders[key.lowercased()] = value
                }
            }

            let bodyString: String
            if isBinary {
                bodyString = data?.base64EncodedString() ?? ""
            } else {
                bodyString = String(data: data ?? Data(), encoding: .utf8) ?? ""
            }

            let networkResponse = NetworkResponse(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                body: bodyString,
                rawData: data,
                finalURL: httpResponse.url?.absoluteString
            )

            Logger.debug("[NET] \(httpResponse.statusCode) \(url) (\(bodyString.count) bytes)")
            completion(.success(networkResponse))
        }

        task.resume()
    }

    // MARK: - 下载

    func download(
        url: String,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let requestUrl = URL(string: url) else {
            completion(.failure(NSError(
                domain: "NetworkManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]
            )))
            return
        }

        let task = session.downloadTask(with: requestUrl) { tempURL, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(NSError(
                    domain: "NetworkManager",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "No data"]
                )))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                completion(.success(destinationURL))
            } catch {
                completion(.failure(error))
            }
        }

        // 使用 KVO 监听下载进度
        let observation = task.progress.observe(\.fractionCompleted) { prog, _ in
            DispatchQueue.main.async {
                progress(prog.fractionCompleted)
            }
        }

        // 存储 observation 防止释放
        objc_setAssociatedObject(task, &NetworkManager.kvoContext, observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }

    private static var kvoContext: Int = 0

    // MARK: - 图片加载

    private var imageCache = NSCache<NSString, NSData>()

    func loadImage(url: String, completion: @escaping (Data?) -> Void) {
        let cacheKey = url as NSString

        if let cached = imageCache.object(forKey: cacheKey) {
            completion(cached as Data)
            return
        }

        guard let requestUrl = URL(string: url) else {
            completion(nil)
            return
        }

        session.dataTask(with: requestUrl) { [weak self] data, _, _ in
            if let data = data {
                self?.imageCache.setObject(data as NSData, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                completion(data)
            }
        }.resume()
    }
}
