import Foundation
import CommonCrypto
import Security

/// 加密工具 — 供 JS 脚本引擎和 Swift 层共用
/// 实现 MD5 / AES / RSA / Base64 / SHA
class Crypto {

    // MARK: - MD5

    static func md5(_ string: String) -> String {
        let length = Int(CC_MD5_DIGEST_LENGTH)
        var digest = [UInt8](repeating: 0, count: length)

        if let data = string.data(using: .utf8) {
            _ = data.withUnsafeBytes { body in
                CC_MD5(body.baseAddress, CC_LONG(data.count), &digest)
            }
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ data: Data) -> String {
        let length = Int(CC_MD5_DIGEST_LENGTH)
        var digest = [UInt8](repeating: 0, count: length)

        _ = data.withUnsafeBytes { body in
            CC_MD5(body.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SHA256

    static func sha256(_ string: String) -> String {
        let data = string.data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        _ = data.withUnsafeBytes { body in
            CC_SHA256(body.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AES

    /// AES 加密
    /// - Parameters:
    ///   - data: 原始数据 (Base64 编码)
    ///   - key: 密钥 (Base64 编码)
    ///   - mode: 加密模式 "cbc" / "ecb"
    /// - Returns: Base64 编码的密文
    static func aesEncrypt(_ data: String, key: String, mode: String) -> String {
        guard let inputData = Data(base64Encoded: data),
              let keyData = key.data(using: .utf8) else { return "" }

        let encrypted = aesOperation(inputData, keyData: keyData, mode: mode, operation: CCOperation(kCCEncrypt))
        return encrypted.base64EncodedString()
    }

    /// AES 解密
    static func aesDecrypt(_ data: String, key: String, mode: String) -> String {
        guard let inputData = Data(base64Encoded: data),
              let keyData = key.data(using: .utf8) else { return "" }

        let decrypted = aesOperation(inputData, keyData: keyData, mode: mode, operation: CCOperation(kCCDecrypt))
        return decrypted.base64EncodedString()
    }

    /// AES-CBC 加密（显式 IV）— 供脚本引擎 weapi 等使用
    /// - Parameters:
    ///   - data: 原始数据 (Base64 编码)
    ///   - key: 密钥 (UTF8)
    ///   - iv: 初始化向量 (UTF8)
    /// - Returns: Base64 编码的密文
    static func aesCbc(_ data: String, key: String, iv: String) -> String {
        guard let inputData = Data(base64Encoded: data),
              let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return "" }

        let encrypted = aesOperation(inputData, keyData: keyData, ivData: Array(ivData.prefix(kCCBlockSizeAES128)), operation: CCOperation(kCCEncrypt))
        return encrypted.base64EncodedString()
    }

    private static func aesOperation(_ data: Data, keyData: Data, mode: String, operation: CCOperation) -> Data {
        let keyLength = kCCKeySizeAES128
        let keyBytes = Array(keyData.prefix(keyLength))
        let ivLength = kCCBlockSizeAES128
        let dataBytes = Array(data)

        var buffer = [UInt8](repeating: 0, count: dataBytes.count + ivLength)
        var numBytesProcessed: size_t = 0
        let bufferCapacity = buffer.count

        let iv: [UInt8]?
        if mode.lowercased() == "cbc" {
            iv = Array(keyData.suffix(ivLength))
        } else {
            iv = nil
        }

        let status = keyBytes.withUnsafeBufferPointer { keyPtr in
            dataBytes.withUnsafeBufferPointer { dataPtr in
                buffer.withUnsafeMutableBufferPointer { bufferPtr in
                    if let iv = iv {
                        return iv.withUnsafeBufferPointer { ivPtr in
                            CCCrypt(
                                operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyLength,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, dataBytes.count,
                                bufferPtr.baseAddress, bufferCapacity,
                                &numBytesProcessed
                            )
                        }
                    } else {
                        return CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyPtr.baseAddress, keyLength,
                            nil,
                            dataPtr.baseAddress, dataBytes.count,
                            bufferPtr.baseAddress, bufferCapacity,
                            &numBytesProcessed
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            Logger.error("AES operation failed: \(status)")
            return Data()
        }

        return Data(bytes: buffer, count: numBytesProcessed)
    }

    /// AES 运算（显式 IV）— CBC 模式使用传入的 iv，ECB 忽略
    private static func aesOperation(_ data: Data, keyData: Data, ivData: [UInt8], operation: CCOperation) -> Data {
        let keyLength = kCCKeySizeAES128
        let keyBytes = Array(keyData.prefix(keyLength))
        let ivLength = kCCBlockSizeAES128
        let dataBytes = Array(data)

        var buffer = [UInt8](repeating: 0, count: dataBytes.count + ivLength)
        var numBytesProcessed: size_t = 0
        let bufferCapacity = buffer.count

        let status = keyBytes.withUnsafeBufferPointer { keyPtr in
            dataBytes.withUnsafeBufferPointer { dataPtr in
                buffer.withUnsafeMutableBufferPointer { bufferPtr in
                    return ivData.withUnsafeBufferPointer { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyLength,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, dataBytes.count,
                            bufferPtr.baseAddress, bufferCapacity,
                            &numBytesProcessed
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            Logger.error("AES operation failed: \(status)")
            return Data()
        }

        return Data(bytes: buffer, count: numBytesProcessed)
    }

    // MARK: - RSA

    static func rsaEncrypt(_ data: String, publicKey: String) -> String {
        guard let inputData = data.data(using: .utf8) else { return "" }

        // 清理 PEM 格式
        let cleanedKey = publicKey
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: cleanedKey) else { return "" }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            Logger.error("RSA key creation failed: \(error?.takeRetainedValue().localizedDescription ?? "")")
            return ""
        }

        guard let encrypted = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            inputData as CFData,
            &error
        ) as Data? else {
            Logger.error("RSA encryption failed: \(error?.takeRetainedValue().localizedDescription ?? "")")
            return ""
        }

        return encrypted.base64EncodedString()
    }

    // MARK: - Base64

    static func base64Encode(_ string: String) -> String {
        return Data(string.utf8).base64EncodedString()
    }

    static func base64Decode(_ string: String) -> String {
        if let data = Data(base64Encoded: string) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    // MARK: - URL Encode

    static func urlEncode(_ string: String) -> String {
        return string.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? string
    }
}
