import Foundation
import Security
import CommonCrypto

/// LX Music 桌面版同步协议所需加密原语
/// 严格对齐 lx-music-desktop `src/main/modules/sync/utils.ts`、`client/auth.ts`、`client/utils.ts`
enum LXSyncCrypto {

    // MARK: - RSA 密钥对（2048，SPKI PEM 公钥）

    /// 生成 RSA-2048 密钥对，返回 (PEM 公钥字符串, 私钥 SecKey)
    /// 公钥格式对齐 Node `generateKeyPair('rsa', { modulusLength:2048, publicKeyEncoding:{type:'spki',format:'pem'} })`
    static func generateRSAKeyPair() -> (publicPEM: String, privateKey: SecKey)? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var publicKey: SecKey?
        var privateKey: SecKey?
        let status = SecKeyGeneratePair(attrs as CFDictionary, &publicKey, &privateKey)
        guard status == errSecSuccess, let priv = privateKey else {
            Logger.error("LX RSA generate failed: \(status)")
            return nil
        }
        let pub = publicKey ?? SecKeyCopyPublicKey(priv)
        guard let pub = pub else { return nil }
        guard let pubData = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return nil }
        // ⚠️ 关键：SecKeyCopyExternalRepresentation 对 RSA 公钥返回的是 **PKCS#1** DER
        // （RSAPublicKey: SEQUENCE { modulus, publicExponent }），
        // 而 PEM 头 "-----BEGIN PUBLIC KEY-----" 表示的是 **SPKI**（SubjectPublicKeyInfo）。
        // 以前这里直接把 PKCS#1 套上 SPKI 的头发出去，桌面端 Node 的
        // crypto.createPublicKey() 解析失败 → rsaEncrypt() 抛异常 → /ah 请求被挂起不响应，
        // 客户端表现为「认证超时」。这是 LX 同步一直连不上的根本原因。
        // 安卓版 codeAuth 不发送公钥（走 AES 响应），所以从不触发这条路径。
        guard let spki = Self.pkcs1ToSPKI(pkcs1: pubData) else { return nil }
        let b64 = spki.base64EncodedString()
        let pem = "-----BEGIN PUBLIC KEY-----\n" + wrapPEM(b64) + "-----END PUBLIC KEY-----"
        return (pem, priv)
    }

    /// PKCS#1 (RSAPublicKey) DER → SPKI (SubjectPublicKeyInfo) DER
    ///
    /// SPKI 结构：SEQUENCE { AlgorithmIdentifier, BIT STRING { PKCS#1 } }
    /// AlgorithmIdentifier for rsaEncryption = 30 0D 06 09 2A 86 48 86 F7 0D 01 01 01 05 00
    private static func pkcs1ToSPKI(pkcs1: Data) -> Data? {
        let algId: [UInt8] = [
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,  // rsaEncryption OID
            0x05, 0x00,                                                        // NULL
        ]
        let pkcs1Bytes = [UInt8](pkcs1)
        // BIT STRING 内容 = 1 字节「未使用位数」(0x00) + PKCS#1 DER
        let bitStringContentLen = pkcs1Bytes.count + 1
        var bitString: [UInt8] = [0x03]
        bitString.append(contentsOf: derLength(bitStringContentLen))
        bitString.append(0x00)
        bitString.append(contentsOf: pkcs1Bytes)

        let inner = algId + bitString
        var spki: [UInt8] = [0x30]
        spki.append(contentsOf: derLength(inner.count))
        spki.append(contentsOf: inner)
        return Data(spki)
    }

    /// DER 长度字段编码（短格式 / 长格式）
    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n < 0x100 { return [0x81, UInt8(n)] }
        if n < 0x10000 { return [0x82, UInt8(n >> 8), UInt8(n & 0xff)] }
        return [0x83, UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    }

    private static func wrapPEM(_ b64: String) -> String {
        var out = ""
        var i = b64.startIndex
        while i < b64.endIndex {
            let end = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += String(b64[i..<end]) + "\n"
            i = end
        }
        return out
    }

    // MARK: - RSA-OAEP 解密（SHA-1，对应 Node RSA_PKCS1_OAEP_PADDING）

    /// 用客户端私钥解密服务端回传的 AES key 等信息
    static func rsaOAEPDecrypt(base64Cipher: String, privateKey: SecKey) -> Data? {
        guard let data = Data(base64Encoded: base64Cipher) else { return nil }
        var err: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey, SecKeyAlgorithm.rsaEncryptionOAEPSHA1,
            data as CFData, &err
        ) as Data? else {
            Logger.error("LX RSA OAEP decrypt failed: \(err?.takeRetainedValue().localizedDescription ?? "")")
            return nil
        }
        return plain
    }

    // MARK: - LX AES-128-ECB（utf8 明文 -> base64 密文，key 为 base64 解码后的 16 字节）

    static func aesEncryptLX(plaintext: String, keyBase64: String) -> String {
        guard let keyData = Data(base64Encoded: keyBase64),
              let input = plaintext.data(using: .utf8) else { return "" }
        let keyBytes = [UInt8](keyData.prefix(16))
        var buf = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let bufCount = buf.count
        var num: size_t = 0
        let st = keyBytes.withUnsafeBytes { kp in
            input.withUnsafeBytes { ip in
                buf.withUnsafeMutableBytes { bp in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            kp.baseAddress, kCCKeySizeAES128, nil,
                            ip.baseAddress, input.count, bp.baseAddress, bufCount, &num)
                }
            }
        }
        guard st == kCCSuccess else { return "" }
        return Data(buf.prefix(num)).base64EncodedString()
    }

    static func aesDecryptLX(cipherBase64: String, keyBase64: String) -> String {
        guard let keyData = Data(base64Encoded: keyBase64),
              let input = Data(base64Encoded: cipherBase64) else { return "" }
        let keyBytes = [UInt8](keyData.prefix(16))
        var buf = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let bufCount = buf.count
        var num: size_t = 0
        let st = keyBytes.withUnsafeBytes { kp in
            input.withUnsafeBytes { ip in
                buf.withUnsafeMutableBytes { bp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            kp.baseAddress, kCCKeySizeAES128, nil,
                            ip.baseAddress, input.count, bp.baseAddress, bufCount, &num)
                }
            }
        }
        guard st == kCCSuccess else { return "" }
        return String(data: Data(buf.prefix(num)), encoding: .utf8) ?? ""
    }

    // MARK: - 6 位码 -> AES key
    // 对齐 client/auth.ts：key = toMD5(authCode).substring(0,16) -> Buffer.from(key) -> base64

    static func keyFromAuthCode(_ code: String) -> String {
        let md5hex = Crypto.md5(code)        // 32 位小写 hex
        let prefix16 = String(md5hex.prefix(16)) // 16 个字符
        let bytes = [UInt8](prefix16.utf8)    // 16 字节
        return Data(bytes).base64EncodedString()
    }

    // MARK: - gzip 编解码（对齐 Node zlib.gzip / gunzip）

    /// 标准 gzip 编码 -> base64
    static func gzipString(_ s: String) -> String? {
        guard let data = s.data(using: .utf8) else { return nil }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lxg_\(UUID().uuidString).gz")
        var file: gzFile?
        "wb9".withCString { mode in
            tmp.path.withCString { path in
                file = gzopen(path, mode)
            }
        }
        guard let fp = file else { return nil }
        defer { gzclose(fp) }
        var written: Int = 0
        data.withUnsafeBytes { ptr in
            written = Int(gzwrite(fp, ptr.baseAddress!, UInt32(data.count)))
        }
        guard written == data.count else { return nil }
        return try? Data(contentsOf: tmp).base64EncodedString()
    }

    /// 标准 gzip 解码（输入 base64，对应 LX 的 cg_ 前缀内容）-> utf8 字符串
    static func gunzipString(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return gunzipData(data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 标准 gzip 解码（输入原始 Data，首两字节为 0x1f 0x8b）-> 解压后的 Data
    /// 供 LX 桌面版导出的 .lxmc（gzip 压缩的 JSON）使用
    static func gunzipData(_ data: Data) -> Data? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lxg_\(UUID().uuidString).gz")
        try? data.write(to: tmp)
        var file: gzFile?
        "rb".withCString { mode in
            tmp.path.withCString { path in
                file = gzopen(path, mode)
            }
        }
        guard let fp = file else { return nil }
        defer { gzclose(fp) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let bufCount = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                Int(gzread(fp, ptr.baseAddress!, UInt32(bufCount)))
            }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    // MARK: - 线格式 encodeData / decodeData（LX 约定 >1024 字节 gzip 加 cg_ 前缀）

    /// 客户端发送：超 1024 字节则 gzip+前缀，否则原样 JSON
    static func encodeData(_ json: String) -> String {
        if json.utf8.count > 1024, let gz = gzipString(json) {
            return "cg_" + gz
        }
        return json
    }

    /// 接收端：有 cg_ 前缀则解 gzip，否则原样
    static func decodeData(_ data: String) -> String {
        if data.hasPrefix("cg_") {
            let b64 = String(data.dropFirst(3))
            return gunzipString(b64) ?? ""
        }
        return data
    }
}
