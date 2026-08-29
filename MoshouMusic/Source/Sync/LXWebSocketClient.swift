import Foundation
import CommonCrypto

/// 极简 WebSocket 客户端（v1.0.55）
///
/// 实现原因：iOS 14.7.1 的 URLSessionWebSocketTask 在收到 LX 桌面端 ws 库的 101
/// 响应后会拒绝完成握手（即使 Sec-WebSocket-Accept / Connection / Upgrade 都正确），
/// 报 "The operation couldn't be completed. Socket is not connected."
///
/// 这里改用 URLSessionStreamTask 拿 TCP 字节流，自己完成 WebSocket 协议：
///   - HTTP upgrade 握手（生成 Sec-WebSocket-Key + 验证 Sec-WebSocket-Accept）
///   - text 帧收发（客户端发帧必须掩码，服务端发帧不掩码）
///   - ping 自动回 pong
///   - 关闭帧
///
/// 仅支持 LX 同步所需；不实现 binary / 扩展 / 压缩（LX 服务端也不发）。
final class LXWebSocketClient: NSObject {

    enum WSError: Error {
        case streamFailed(String)
        case handshakeFailed(String)
    }

    private let streamTask: URLSessionStreamTask
    private let queue = DispatchQueue(label: "LXWS")
    private var readBuffer = Data()
    private let secWebSocketKey: String
    private let expectedAccept: String
    private let upgradeRequest: Data

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Int?, String?) -> Void)?
    var onError: ((Error) -> Void)?

    init(url: URL) {
        let scheme = url.scheme == "wss" ? "tls" : "tcp"
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? (scheme == "tls" ? 443 : 80)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)

        // 16 字节随机 Sec-WebSocket-Key
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        self.secWebSocketKey = key
        self.expectedAccept = LXWebSocketClient.computeAccept(for: key)

        // 构造 HTTP upgrade 请求（与 iOS URLSessionWebSocketTask 自动发的格式一致）
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?\(q)" }
        let req = """
        GET \(path) HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        self.upgradeRequest = Data(req.utf8)
        self.streamTask = session.streamTask(withHostName: host, port: port)
        super.init()
    }

    // MARK: - 连接

    func connect() {
        streamTask.write(upgradeRequest, timeout: 10) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.fail(.streamFailed("write upgrade: \(error.localizedDescription)"))
                return
            }
            self.readHttpResponse()
        }
        streamTask.resume()
    }

    private func readHttpResponse() {
        streamTask.readData(ofMinLength: 1, maxLength: 4096, timeout: 10) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                self.fail(.streamFailed("read http: \(error.localizedDescription)"))
                return
            }
            guard let data = data, !data.isEmpty else { return }
            self.queue.async {
                self.readBuffer.append(data)
                self.tryParseHttpResponse()
            }
        }
    }

    private func tryParseHttpResponse() {
        let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
        guard let r = readBuffer.range(of: marker) else {
            // header 还没读完，再读
            readHttpResponse()
            return
        }
        let headerData = readBuffer.subdata(in: 0..<r.lowerBound)
        let after = readBuffer.subdata(in: r.upperBound..<readBuffer.count)
        readBuffer = Data()
        guard let s = String(data: headerData, encoding: .utf8) else {
            fail(.handshakeFailed("response header not utf8"))
            return
        }
        let lines = s.split(separator: "\r\n")
        guard let first = lines.first, first.contains("101") else {
            fail(.handshakeFailed("status not 101: \(String(first ?? ""))"))
            return
        }
        // 验证 Sec-WebSocket-Accept
        let accept = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") })
            .map { String($0.dropFirst("sec-websocket-accept:".count)).trimmingCharacters(in: .whitespaces) }
        guard accept == expectedAccept else {
            fail(.handshakeFailed("accept mismatch: got=\(accept ?? "nil") want=\(expectedAccept)"))
            return
        }
        Logger.info("LX WS handshake ok: \(s.prefix(120))")
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        if !after.isEmpty { parseFrames(after) }
        readNextFrames()
    }

    // MARK: - 读 WebSocket 帧

    private func readNextFrames() {
        streamTask.readData(ofMinLength: 1, maxLength: 65536, timeout: -1) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                self.fail(.streamFailed("read ws: \(error.localizedDescription)"))
                return
            }
            guard let data = data, !data.isEmpty else { return }
            self.queue.async {
                self.readBuffer.append(data)
                self.parseFrames(self.readBuffer)
            }
        }
    }

    private func parseFrames(_ data: Data) {
        var d = data
        while d.count >= 2 {
            let b0 = d[d.startIndex]
            let b1 = d[d.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var o = d.startIndex + 2
            if len == 126 {
                guard d.count >= o + 2 else { break }
                len = Int(d[o]) << 8 | Int(d[o + 1])
                o += 2
            } else if len == 127 {
                guard d.count >= o + 8 else { break }
                var v: UInt64 = 0
                for i in 0..<8 { v = (v << 8) | UInt64(d[o + i]) }
                len = Int(v)
                o += 8
            }
            let maskRange: Range<Int>? = masked ? (d.count >= o + 4 ? o..<(o + 4) : nil) : nil
            if masked && maskRange == nil { break }
            let mo = o + (masked ? 4 : 0)
            let need = mo + len
            guard d.count >= need else { break }
            var payload = d.subdata(in: mo..<need)
            if masked, let r = maskRange {
                let m = d.subdata(in: r)
                for i in 0..<payload.count { payload[i] ^= m[i % 4] }
            }
            if fin { handleFrame(opcode: opcode, payload: payload) }
            d = d.subdata(in: need..<d.count)
        }
        readBuffer = d
    }

    private func handleFrame(opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1:  // text
            if let s = String(data: payload, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in self?.onText?(s) }
            }
        case 0x8:  // close
            let code: Int? = payload.count >= 2
                ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
                : nil
            let reason = payload.count > 2
                ? String(data: payload.dropFirst(2), encoding: .utf8)
                : nil
            streamTask.closeRead(); streamTask.closeWrite()
            DispatchQueue.main.async { [weak self] in self?.onClose?(code, reason) }
        case 0x9:  // ping → 自动回 pong（携带相同 payload）
            sendFrame(opcode: 0xA, payload: payload)
        case 0xA:  // pong, ignore
            break
        default:
            break
        }
    }

    // MARK: - 发 WebSocket 帧

    /// 发 text 帧（同步协议只走 text，JSON 经过 base64 编码的 message2call 协议）
    func send(text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// 发 close 帧（1000 Normal Closure + "bye"）
    func close() {
        var p = Data([0x03, 0xE8])  // 1000
        p.append(Data("bye".utf8))
        sendFrame(opcode: 0x8, payload: p)
        streamTask.closeRead(); streamTask.closeWrite()
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        // 客户端必须掩码（mask=1）
        var mk = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mk)
        var masked = payload
        for i in 0..<masked.count { masked[i] ^= mk[i % 4] }
        var f = Data()
        f.append(0x80 | opcode)  // FIN=1
        let l = payload.count
        if l < 126 {
            f.append(0x80 | UInt8(l))
        } else if l < 65536 {
            f.append(0x80 | 126)
            f.append(UInt8((l >> 8) & 0xFF))
            f.append(UInt8(l & 0xFF))
        } else {
            f.append(0x80 | 127)
            var v = UInt64(l)
            for _ in 0..<8 { f.append(UInt8((v >> 56) & 0xFF)); v <<= 8 }
        }
        f.append(contentsOf: mk)
        f.append(masked)
        streamTask.write(f, timeout: 10) { _ in }
    }

    private func fail(_ error: WSError) {
        Logger.error("LX WS error: \(error)")
        streamTask.closeRead(); streamTask.closeWrite()
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: - Sec-WebSocket-Accept

    /// RFC 6455: accept = base64(sha1(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    private static func computeAccept(for key: String) -> String {
        let combined = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let bytes = Array(combined.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(bytes, CC_LONG(bytes.count), &hash)
        return Data(hash).base64EncodedString()
    }
}
