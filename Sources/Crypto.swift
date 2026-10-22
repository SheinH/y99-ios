import Foundation
import CommonCrypto

// Port of the "saira" helper (deob/modules/gUCs.js): CryptoJS passphrase AES,
// used to build the `r` form field that every API call carries while app.ajas is on.
enum Saira {
    static let key = Secrets.sairaKey

    static func md5(_ d: Data) -> Data {
        var h = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(d.count), &h) }
        return Data(h)
    }

    // OpenSSL EVP_BytesToKey(MD5, 1 iteration)
    static func evp(pass: Data, salt: Data, keyLen: Int = 32, ivLen: Int = 16) -> (Data, Data) {
        var d = Data(); var prev = Data()
        while d.count < keyLen + ivLen { prev = md5(prev + pass + salt); d.append(prev) }
        return (d.prefix(keyLen), d.subdata(in: keyLen ..< keyLen + ivLen))
    }

    static func aesCBC(_ data: Data, key: Data, iv: Data) -> Data {
        let bufSize = data.count + kCCBlockSizeAES128
        var out = Data(count: bufSize); var moved = 0
        _ = out.withUnsafeMutableBytes { ob in
            data.withUnsafeBytes { db in key.withUnsafeBytes { kb in iv.withUnsafeBytes { ivb in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, key.count, ivb.baseAddress,
                        db.baseAddress, data.count, ob.baseAddress, bufSize, &moved)
            }}}}
        return out.prefix(moved)
    }

    static func encrypt(value: String) -> String {
        let salt = Data((0 ..< 8).map { _ in UInt8.random(in: 0 ... 255) })
        let (k, iv) = evp(pass: Data(key.utf8), salt: salt)
        let plain = (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data("\"\(value)\"".utf8)
        let ct = aesCBC(plain, key: k, iv: iv)
        let wrapped = "{\"ct\":\"\(ct.base64EncodedString())\",\"iv\":\"\(iv.hex)\",\"s\":\"\(salt.hex)\"}"
        return Data(wrapped.utf8).base64EncodedString()
    }
}

extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
