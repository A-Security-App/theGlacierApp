//
//  GlacierPinningConfiguration.swift
//
//  Centralised SSL certificate pinning for all backend connections.
//  A TLS connection is accepted when standard validation passes AND at least
//  one certificate in the server's chain has an SPKI SHA-256 hash that matches
//  a value in GlacierPinningConfiguration.pinnedHashes.
//
//  Pinned CAs:
//  Amazon Trust Services (AWS infrastructure: ALBs, NLBs):
//    • Amazon RSA 2048 M01 — intermediate CA on ALB endpoints
//    • Amazon RSA 2048 M04 — intermediate CA on NLB endpoints
//    • Amazon Root CA 1    — backup pin; common root of both M01/M04 chains
//
//  To derive a new pin hash from a live endpoint:
//    openssl s_client -connect <host>:443 -showcerts </dev/null 2>/dev/null | \
//      awk '/BEGIN CERTIFICATE/{c++} c==2{print}' | \
//      openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | \
//      openssl dgst -sha256 -binary | base64
import Foundation
import Alamofire
import CommonCrypto
// MARK: - SPKI DER Header Bytes
//
// SecKeyCopyExternalRepresentation returns the raw key bytes only — it does NOT
// include the algorithm OID wrapper that OpenSSL includes in SubjectPublicKeyInfo
// (SPKI) DER. We prepend the appropriate fixed header to reconstruct the full
// SPKI before hashing, so that our computed hash matches the OpenSSL output.
private enum SPKIHeader {
    /// RSA 2048-bit (covers Amazon RSA 2048 M01, M04, Root CA 1)
    static let rsa2048: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]
    /// RSA 4096-bit
    static let rsa4096: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
    ]
    /// EC P-256
    static let ecP256: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00
    ]
    /// EC P-384
    static let ecP384: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
        0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
    ]
}
// MARK: - Pinning Configuration
enum GlacierPinningConfiguration {
    // MARK: Pinned CA Hashes
    /// Amazon RSA 2048 M01 — intermediate CA on ALB endpoints
    static let amazonRSA2048M01 = "DxH4tt40L+eduF6szpY6TONlxhZhBd+pJ9wbHlQ2fuw="
    /// Amazon RSA 2048 M04 — intermediate CA on NLB endpoints
    static let amazonRSA2048M04 = "G9LNNAql897egYsabashkzUCTEJkWBzgoEtk8X/678c="
    /// Amazon Root CA 1 — backup pin; root of both M01 and M04 chains
    static let amazonRootCA1    = "++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI="
    /// Google Trust Services WE1 — intermediate CA on staging/tracking endpoints (EC P-256)
    static let googleWE1        = "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4="
    /// Google Trust Services Root R4 — backup pin; root of the WE1 chain
    static let googleTSRootR4   = "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c="
    /// Full set of accepted pins. A connection passes when any cert in its chain
    /// matches at least one of these hashes.
    static let pinnedHashes: Set<String> = [
        amazonRSA2048M01,
        amazonRSA2048M04,
        amazonRootCA1,
        googleWE1,
        googleTSRootR4
    ]
    // MARK: Alamofire Integration
    /// Shared pinned Session for use in contexts that cannot hold a stored property
    /// (e.g. AppDelegate extensions). Initialised once and reused across calls.
    static let pinnedSession = Session(serverTrustManager: makeServerTrustManager())
    /// Returns a ServerTrustManager that enforces CA pinning on every host
    /// without requiring domain names to be listed in source code.
    static func makeServerTrustManager() -> ServerTrustManager {
        GlacierServerTrustManager()
    }
    // MARK: Shared Utilities
    /// Extracts all certificates from a SecTrust chain.
    static func certificateChain(for trust: SecTrust) -> [SecCertificate] {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }
    /// Returns true if any certificate in the trust's chain has an SPKI SHA-256
    /// hash matching one of the pinned hashes. Does NOT perform trust evaluation;
    /// call SecTrustEvaluateWithError separately before this.
    static func chainContainsPinnedCA(trust: SecTrust) -> Bool {
        certificateChain(for: trust)
            .compactMap { spkiSHA256Hash(for: $0) }
            .contains { pinnedHashes.contains($0) }
    }
    /// Computes the SPKI SHA-256 hash of a certificate's public key, base64-encoded.
    /// The result matches the output of:
    ///   openssl x509 -pubkey -noout | openssl pkey -pubin -outform der |
    ///   openssl dgst -sha256 -binary | base64
    static func spkiSHA256Hash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        var keyError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data? else {
            return nil
        }
        guard let header = spkiHeader(for: publicKey) else { return nil }
        var spki = Data(header)
        spki.append(keyData)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        spki.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(spki.count), &digest) }
        return Data(digest).base64EncodedString()
    }
    // MARK: Private
    private static func spkiHeader(for key: SecKey) -> [UInt8]? {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any] else { return nil }
        let type = attrs[kSecAttrKeyType as String] as? String
        let size = attrs[kSecAttrKeySizeInBits as String] as? Int
        let rsa = kSecAttrKeyTypeRSA as String
        let ec  = kSecAttrKeyTypeECSECPrimeRandom as String
        if type == rsa && size == 2048 { return SPKIHeader.rsa2048 }
        if type == rsa && size == 4096 { return SPKIHeader.rsa4096 }
        if type == ec  && size == 256  { return SPKIHeader.ecP256 }
        if type == ec  && size == 384  { return SPKIHeader.ecP384 }
        return nil
    }
}
// MARK: - Error
enum GlacierPinningError: LocalizedError {
    case noPinnedCertificateInChain
    var errorDescription: String? {
        "SSL certificate chain does not contain a pinned CA. Connection rejected."
    }
}
// MARK: - Alamofire ServerTrustManager
/// Subclass that returns GlacierPinnedCAEvaluator for every host, applying
/// CA pinning globally without hardcoding any domain names.
final class GlacierServerTrustManager: ServerTrustManager {
    private let evaluator = GlacierPinnedCAEvaluator()
    init() { super.init(allHostsMustBeEvaluated: true, evaluators: [:]) }
    override func serverTrustEvaluator(forHost host: String) throws -> ServerTrustEvaluating? {
        evaluator
    }
}
// MARK: - Custom Trust Evaluator
/// Performs standard TLS validation then verifies the certificate chain
/// contains at least one of Glacier's pinned CA public key hashes.
final class GlacierPinnedCAEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws {
        // 1. Standard validation: chain validity + hostname
        var cfError: CFError?
        guard SecTrustEvaluateWithError(trust, &cfError) else {
            throw AFError.serverTrustEvaluationFailed(reason: .trustEvaluationFailed(error: cfError))
        }
        // 2. CA pinning
        guard GlacierPinningConfiguration.chainContainsPinnedCA(trust: trust) else {
            throw AFError.serverTrustEvaluationFailed(
                reason: .customEvaluationFailed(error: GlacierPinningError.noPinnedCertificateInChain)
            )
        }
    }
}
