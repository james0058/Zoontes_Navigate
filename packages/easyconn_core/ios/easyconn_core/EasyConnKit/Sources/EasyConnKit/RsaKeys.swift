import Foundation
import Security

/// Mirrors the Carbit SDK's RSAUtil: a 1024-bit keypair, X.509 public key in CLIENT_INFO, and the
/// bike's HUID "encrypted with the private key" (= PKCS#1 v1.5 type-1 padding of the raw bytes, no hash).
public final class RsaKeys {
    private let privateKey: SecKey
    public let publicKey: SecKey

    public init() throws {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(priv) else {
            throw EasyConnError.crypto("keygen: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        privateKey = priv
        publicKey = pub
    }

    /// Base64 SubjectPublicKeyInfo (what Java's PublicKey.getEncoded() produces).
    public var publicKeyBase64: String {
        var err: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else { return "" }
        return Self.spki(fromPKCS1: pkcs1).base64EncodedString()
    }

    public func signHuid(_ huid: String) throws -> String {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15Raw,
                                              Data(huid.utf8) as CFData, &err) as Data? else {
            throw EasyConnError.crypto("sign: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return sig.base64EncodedString()
    }

    static func spki(fromPKCS1 pkcs1: Data) -> Data {
        let algId: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = der(tag: 0x03, Data([0x00]) + pkcs1)
        return der(tag: 0x30, Data(algId) + bitString)
    }

    private static func der(tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        let n = body.count
        if n < 0x80 { out.append(UInt8(n)) }
        else if n < 0x100 { out.append(contentsOf: [0x81, UInt8(n)]) }
        else { out.append(contentsOf: [0x82, UInt8(n >> 8), UInt8(n & 0xff)]) }
        return out + body
    }
}
