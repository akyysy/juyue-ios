import Foundation
import CryptoKit

public enum CryptoUtils {

    public static func md5(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func base64Encode(_ string: String) -> String {
        return Data(string.utf8).base64EncodedString()
    }

    public static func base64Decode(_ string: String) -> String {
        guard let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 书源脚本里的摘要工具（java.digestHex / java.HMacHex / java.HMacBase64）

    /// 把 `sha-256`、`SHA256`、`md5hex` 这类写法归一成 `sha256` / `md5`。
    static func normalizeAlgorithm(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "hex", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `java.digestHex("SHA-256", "abc")` → 十六进制摘要。不认识的算法返回空串。
    public static func digestHex(_ algorithm: String, _ string: String) -> String {
        let data = Data(string.utf8)
        switch normalizeAlgorithm(algorithm) {
        case "md5":
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha256":
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha384":
            return SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return ""
        }
    }

    public static func hmacHex(_ algorithm: String, key: String, data: String) -> String {
        guard let mac = hmacBytes(algorithm, key: key, data: data) else { return "" }
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacBase64(_ algorithm: String, key: String, data: String) -> String {
        guard let mac = hmacBytes(algorithm, key: key, data: data) else { return "" }
        return Data(mac).base64EncodedString()
    }

    /// CryptoKit 没有 HMAC-MD5，遇到 md5 返回 nil（脚本会拿到空串，而不是崩溃）。
    private static func hmacBytes(_ algorithm: String, key: String, data: String) -> [UInt8]? {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let payload = Data(data.utf8)
        switch normalizeAlgorithm(algorithm) {
        case "sha1":
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: payload, using: symmetricKey))
        case "sha256":
            return Array(HMAC<SHA256>.authenticationCode(for: payload, using: symmetricKey))
        case "sha384":
            return Array(HMAC<SHA384>.authenticationCode(for: payload, using: symmetricKey))
        case "sha512":
            return Array(HMAC<SHA512>.authenticationCode(for: payload, using: symmetricKey))
        default:
            return nil
        }
    }
}
