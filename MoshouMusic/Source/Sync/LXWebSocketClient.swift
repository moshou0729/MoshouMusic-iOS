import Foundation
import CommonCrypto
import Darwin

/// 极简 WebSocket 客户端（v1.0.68：BSD socket 传输层）
///
/// 实现原因：iOS 14.7.1 的 URLSessionWebSocketTask 在收到 LX 桌面端 ws 库的 101
/// 响应后会拒绝完成握手（即使 Sec-WebSocket-Accept / Connection / Upgrade 都正确），
/// 报 "The operation couldn't be completed. Socket is not connected."
///
/// v1.0.55~v1.0.67 用 `URLSessionStreamTask` 自己完成 RFC 6455，但踩了两个黑盒坑：
///   - v1.0.62：`readData` 是非阻塞 I/O，data 可能为空就回调，必须空数据也续读；
///   - v1.0.64：两个 `readData` 链并存会互相 cancel（NSURLErrorCancelled -999）；
///   - v1.0.65~v1.0.67（怀疑根因）：URLSessionStreamTask 内部把 read / write **串行排队**，
///     而我们一直挂着一个 `readData(timeout: -1)`（等下一帧，永不超时），
///     导致随后 enqueue 的 **write（我们的 RESPONSE 帧）被堵在读后面永远发不出去** ——
///     这正好解释「UI 显示『已发送 getEnabledFeatures』，桌面端却毫无反应、
///     30 秒心跳 ping 到达后才有动静」。
///
/// v1.0.68 直接用 BSD socket：一个专用 I/O 线程跑 `poll()` 事件循环，
/// 读与写互不阻塞、写队列独立、写出结果可统计（UI 能看见到底发出去了没有）。
/// 行为完全可控，不再依赖 URLSession 的内部实现细节。
///
/// 仅支持 LX 同步所需；不实现 binary / 扩展 / 压缩（LX 服务端也不发）。
final class LXWebSocketClient {

    enum WSError: Error {
        case socketFailed(String)
        case handshakeFailed(String)
    }

    // MARK: - 公开回调（全部在主线程回调，与旧实现一致）

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Int?, String?) -> Void)?
    var onError: ((Error) -> Void)?
    /// v1.0.68：传输层细节日志（连上 / 写出 N 字节 / 读到 N 字节），供 UI 诊断
    var onLog: ((String) -> Void)?

    // MARK: - 内部状态

    private let url: URL
    private var fd: Int32 = -1

    /// 专用 I/O 队列：整个事件循环在这里面跑（会长期占用一个线程，这是刻意的）
    private let ioQueue = DispatchQueue(label: "com.moshou.lxws.io")

    /// 保护 `outBuf` / 统计计数器：写方向会被主线程（回包）与 I/O 线程（pong/close）同时触碰
    private let ioLock = NSLock()
    private var outBuf = Data()
    private var writeOKBytes = 0
    private var writeFailCount = 0
    private var lastWriteError: String?
    private var readOKBytes = 0

    /// 只在 I/O 线程访问
    private var readBuf = Data()
    private var httpDone = false
    private var stopped = false
    private var closeSent = false
    private var didNotifyClose = false
    private var shutdownAfterFlush = false

    private let secWebSocketKey: String
    private let expectedAccept: String
    private let upgradeRequest: Data

    // MARK: - Init

    init(url: URL) {
        self.url = url
        let scheme = (url.scheme ?? "ws").lowercased()
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? ((scheme == "wss") ? 443 : 80)

        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        self.secWebSocketKey = key
        self.expectedAccept = LXWebSocketClient.computeAccept(for: key)

        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?\(q)" }
        let req = "GET \(path) HTTP/1.1\r\n" +
                  "Host: \(host):\(port)\r\n" +
                  "Upgrade: websocket\r\n" +
                  "Connection: Upgrade\r\n" +
                  "Sec-WebSocket-Key: \(key)\r\n" +
                  "Sec-WebSocket-Version: 13\r\n" +
                  "\r\n"
        self.upgradeRequest = Data(req.utf8)
    }

    // MARK: - 连接

    func connect() {
        ioQueue.async { [weak self] in self?.run() }
    }

    private func run() {
        let scheme = (url.scheme ?? "ws").lowercased()
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? ((scheme == "wss") ? 443 : 80)

        guard let addrs = Self.resolve(host: host, port: port), !addrs.isEmpty else {
            fail(.socketFailed("域名解析失败：\(host):\(port)"))
            return
        }

        var connected = false
        for item in addrs {
            let family = item.family
            let a = item.addr
            let s = socket(family, SOCK_STREAM, IPPROTO_TCP)
            if s < 0 { continue }
            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))

            a.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                _ = connect(s, base.assumingMemoryBound(to: sockaddr.self), socklen_t(a.count))
            }
            // 非阻塞 connect：等 POLLOUT 再查 SO_ERROR
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let r = poll(&pfd, 1, 8000)
            if r > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 { fd = s; connected = true; break }
                Logger.error("LX WS connect SO_ERROR=\(err) \(String(cString: strerror(err)))")
            } else if r < 0 {
                Logger.error("LX WS connect poll errno=\(errno)")
            }
            Darwin.close(s)
        }
        guard connected else {
            fail(.socketFailed("TCP 连接失败：\(host):\(port)（errno \(errno)）"))
            return
        }
        log("TCP 已连接 \(host):\(port)")

        // 发送 HTTP upgrade 请求
        appendOut(upgradeRequest)
        let handshakeDeadline = Date().addingTimeInterval(15)

        // 事件循环：poll 超时 50ms，保证写队列最迟 50ms 内被排空（旧实现会被 -1 超时的读永久堵住）
        while !stopped {
            if !httpDone && Date() > handshakeDeadline {
                fail(.handshakeFailed("握手超时（15 秒内未收到 101）"))
                return
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            ioLock.lock()
            let hasOut = !outBuf.isEmpty
            ioLock.unlock()
            if hasOut { pfd.events |= Int16(POLLOUT) }

            let r = poll(&pfd, 1, 50)
            if r < 0 {
                if errno == EINTR { continue }
                fail(.socketFailed("poll 错误 errno=\(errno)"))
                return
            }
            if r == 0 {
                // 超时：若已请求关闭且缓冲已空 → 收尾
                if shutdownAfterFlush && !hasOut && !stopped { finishClose(code: nil, reason: nil) }
                continue
            }
            if (pfd.revents & Int16(POLLOUT)) != 0 { drainOut() }
            if (pfd.revents & Int16(POLLIN)) != 0 {
                if !doRead() { return }
            }
            if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                // 有 POLLIN 时上面已经读过一轮；HUP/ERR 就直接收尾，不要再原地打转
                finishClose(code: nil, reason: "连接被对端关闭（HUP/ERR）")
                return
            }
            if shutdownAfterFlush {
                ioLock.lock(); let empty = outBuf.isEmpty; ioLock.unlock()
                if empty && !stopped { finishClose(code: nil, reason: nil); return }
            }
        }
    }

    // MARK: - 读

    /// 返回 false 表示连接已结束（循环应退出）
    private func doRead() -> Bool {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        if n == 0 {
            finishClose(code: nil, reason: "服务端关闭连接（EOF）")
            return false
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return true }
            finishClose(code: nil, reason: "recv 错误 errno=\(errno)")
            return false
        }
        ioLock.lock(); readOKBytes += n; ioLock.unlock()
        readBuf.append(contentsOf: buf[0..<n])
        if !httpDone {
            tryParseHttpResponse()
        } else {
            parseFrames()
        }
        return true
    }

    private func tryParseHttpResponse() {
        let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
        guard let r = readBuf.range(of: marker) else { return }
        let headerData = readBuf.subdata(in: 0..<r.lowerBound)
        let after = readBuf.subdata(in: r.upperBound..<readBuf.count)
        readBuf = Data()
        guard let s = String(data: headerData, encoding: .utf8) else {
            fail(.handshakeFailed("响应头不是 utf8")); return
        }
        let lines = s.split(separator: "\r\n")
        guard let first = lines.first else {
            fail(.handshakeFailed("空响应")); return
        }
        guard first.contains("101") else {
            fail(.handshakeFailed("状态码不是 101：\(first)")); return
        }
        let accept = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") })
            .map { String($0.dropFirst("sec-websocket-accept:".count)).trimmingCharacters(in: .whitespaces) }
        guard accept == expectedAccept else {
            fail(.handshakeFailed("Sec-WebSocket-Accept 不匹配：got=\(accept ?? "nil")"))
            return
        }
        httpDone = true
        log("WS 握手完成（101）")
        Logger.info("LX WS handshake ok: \(s.prefix(120))")
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        if !after.isEmpty { parseFrames() }
    }

    private func parseFrames() {
        var d = readBuf
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
            let mo = o + (masked ? 4 : 0)
            if masked && d.count < mo { break }
            let need = mo + len
            guard d.count >= need else { break }
            var payload = d.subdata(in: mo..<need)
            if masked {
                let m = d.subdata(in: o..<(o + 4))
                for i in 0..<payload.count { payload[i] ^= m[i % 4] }
            }
            if fin { handleFrame(opcode: opcode, payload: payload) }
            d = d.subdata(in: need..<d.count)
        }
        readBuf = d
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
            // 收到对端 close 就收尾（不必再回 close 帧，避免半关闭状态卡住事件循环）
            finishClose(code: code, reason: reason)
        case 0x9:  // ping → 自动回 pong（携带相同 payload）
            appendOut(buildFrame(opcode: 0xA, payload: payload))
        case 0xA:  // pong，忽略
            break
        default:
            break
        }
    }

    // MARK: - 写

    /// 发 text 帧（同步协议只走 text）
    func send(text: String) {
        let frame = buildFrame(opcode: 0x1, payload: Data(text.utf8))
        appendOut(frame)
    }

    /// 发 close 帧（1000 Normal Closure + "bye"）
    func close() {
        var p = Data([0x03, 0xE8])  // 1000
        p.append(Data("bye".utf8))
        closeSent = true
        appendOut(buildFrame(opcode: 0x8, payload: p))
        shutdownAfterFlush = true
    }

    /// v1.0.68：供 UI 诊断——到底写出去了多少字节 / 有没有写失败
    func ioStats() -> (writtenBytes: Int, readBytes: Int, writeFailures: Int, lastError: String?) {
        ioLock.lock()
        defer { ioLock.unlock() }
        return (writeOKBytes, readOKBytes, writeFailCount, lastWriteError)
    }

    private func appendOut(_ data: Data) {
        ioLock.lock()
        outBuf.append(data)
        ioLock.unlock()
    }

    /// 把待写缓冲尽量写进 socket（非阻塞；写不完的留到下一轮）
    /// 只在 I/O 线程调用
    private func drainOut() {
        ioLock.lock()
        guard !outBuf.isEmpty else { ioLock.unlock(); return }
        var pending = outBuf
        outBuf.removeAll(keepingCapacity: true)
        ioLock.unlock()

        var rest = pending
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { p -> Int in
                guard let base = p.baseAddress else { return -1 }
                return send(fd, base, rest.count, 0)
            }
            if n > 0 {
                ioLock.lock(); writeOKBytes += n; ioLock.unlock()
                rest.removeFirst(n)
            } else if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
                let code = errno
                ioLock.lock()
                writeFailCount += 1
                lastWriteError = "send errno=\(code) \(String(cString: strerror(code)))"
                ioLock.unlock()
                fail(.socketFailed("写出失败 errno=\(code) \(String(cString: strerror(code)))"))
                return
            } else {
                break
            }
        }
        if !rest.isEmpty {
            ioLock.lock()
            outBuf.insert(contentsOf: rest, at: 0)
            ioLock.unlock()
        }
    }

    // MARK: - 帧构造

    private func buildFrame(opcode: UInt8, payload: Data) -> Data {
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
        return f
    }

    // MARK: - 收尾

    private func finishClose(code: Int?, reason: String?) {
        if stopped { return }
        stopped = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        guard !didNotifyClose else { return }
        didNotifyClose = true
        Logger.info("LX WS closed code=\(code.map(String.init) ?? "nil") reason=\(reason ?? "")")
        DispatchQueue.main.async { [weak self] in self?.onClose?(code, reason) }
    }

    private func fail(_ error: WSError) {
        if stopped { return }
        Logger.error("LX WS error: \(error)")
        stopped = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private func log(_ s: String) {
        Logger.info("LX WS: \(s)")
        DispatchQueue.main.async { [weak self] in self?.onLog?(s) }
    }

    // MARK: - DNS / Accept

    private static func resolve(host: String, port: Int) -> [(addr: Data, family: Int32)]? {
        var hints = addrinfo(ai_flags: 0,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let st = getaddrinfo(host, String(port), &hints, &res)
        guard st == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var out: [(addr: Data, family: Int32)] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            if let sa = cur.pointee.ai_addr {
                let addr = Data(bytes: UnsafeRawPointer(sa), count: Int(cur.pointee.ai_addrlen))
                out.append((addr: addr, family: cur.pointee.ai_family))
            }
            p = cur.pointee.ai_next
        }
        return out.isEmpty ? nil : out
    }

    /// RFC 6455: accept = base64(sha1(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    private static func computeAccept(for key: String) -> String {
        let combined = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let bytes = Array(combined.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(bytes, CC_LONG(bytes.count), &hash)
        return Data(hash).base64EncodedString()
    }
}
