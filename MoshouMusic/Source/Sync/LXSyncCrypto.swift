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
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyGeneratePair(attrs as CFDictionary, &err) else {
            Logger.error("LX RSA generate failed: \(err?.takeRetainedValue().localizedDescription ?? "")")
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        guard let pubData = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else { return nil }
        // RSA 公钥导出为 SPKI DER -> base64 -> PEM（Node 为 spki/pem）
        let b64 = pubData.base64EncodedString()
        let pem = "-----BEGIN PUBLIC KEY-----\n" + wrapPEM(b64) + "-----END PUBLIC KEY-----"
        return (pem, privateKey)
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
        var num: size_t = 0
        let st = keyBytes.withUnsafeBytes { kp in
            input.withUnsafeBytes { ip in
                buf.withUnsafeMutableBytes { bp in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            kp.baseAddress, kCCKeySizeAES128, nil,
                            ip.baseAddress, input.count, bp.baseAddress, buf.count, &num)
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
        var num: size_t = 0
        let st = keyBytes.withUnsafeBytes { kp in
            input.withUnsafeBytes { ip in
                buf.withUnsafeMutableBytes { bp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            kp.baseAddress, kCCKeySizeAES128, nil,
                            ip.baseAddress, input.count, bp.baseAddress, buf.count, &num)
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
        while true {
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                Int(gzread(fp, ptr.baseAddress!, UInt32(buf.count)))
            }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(data: out, encoding: .utf8)
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
