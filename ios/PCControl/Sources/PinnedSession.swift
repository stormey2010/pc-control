import Foundation
import Security
import CryptoKit

/// The PC has a persistent, self-signed identity. Trust only the leaf that the
/// user provisioned out of band; DNS names and LAN addresses may legitimately change.
final class PinnedSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge,nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format:"%02x",$0) }.joined()
        guard digest == fingerprint else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        // Pinning supplies identity; anchoring the same leaf still checks its
        // validity/signature. A basic policy avoids tying the pin to a DHCP IP.
        SecTrustSetPolicies(trust,SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust,[certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust,true)
        guard SecTrustEvaluateWithError(trust,nil) else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
}
