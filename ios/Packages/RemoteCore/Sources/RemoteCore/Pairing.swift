import Foundation

public struct Pairing: Codable, Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let port: Int
    public let urls: [String]
    public let token: String
    public let certificateSha256: String
    public init(deviceId: String, name: String, port: Int, urls: [String], token: String, certificateSha256: String) {
        self.deviceId = deviceId; self.name = name; self.port = port; self.urls = urls; self.token = token; self.certificateSha256 = certificateSha256.lowercased()
    }
    public enum ValidationError: LocalizedError {
        case invalid, noLocalAddress, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalid: return "This isn’t a valid PC Control setup code. Generate a fresh code on your PC."
            case .noLocalAddress: return "The setup file has no usable local network address. Connect your PC to Wi-Fi or Ethernet and generate a new code."
            case .tooLarge: return "This setup file is too large. Choose the PC Control connection file."
            }
        }
    }
    public static func parse(_ data: Data) throws -> Pairing {
        guard data.count <= 16384 else { throw ValidationError.tooLarge }
        var decoded = data
        if let raw = String(data: data, encoding: .utf8), raw.hasPrefix("pccontrol://") {
            guard let u = URLComponents(string: raw), u.host == "pair", let payload = u.queryItems?.first(where: { $0.name == "data" })?.value else { throw ValidationError.invalid }
            let normalized = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let bytes = Data(base64Encoded: normalized + String(repeating: "=", count: (4-normalized.count%4)%4)) else { throw ValidationError.invalid }
            decoded = bytes
        }
        guard let p = try? JSONDecoder().decode(Pairing.self, from: decoded), !p.deviceId.isEmpty, p.deviceId.count <= 128, !p.name.isEmpty, p.name.count <= 128,
              (1024...65535).contains(p.port), (32...512).contains(p.token.count), p.token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              p.certificateSha256.count == 64, p.certificateSha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw ValidationError.invalid }
        guard !p.endpoints.isEmpty else { throw ValidationError.noLocalAddress }
        return p
    }
    public var endpoints: [URL] {
        urls.compactMap { raw in
            guard let u = URLComponents(string: raw), u.scheme == "https", u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, (u.path.isEmpty || u.path == "/"), let host = u.host, Self.isLocalHost(host), host != "localhost", host != "127.0.0.1", host != "::1", u.port == port else { return nil }
            return u.url
        }.sorted { a,b in Self.addressRank(a.host ?? "") < Self.addressRank(b.host ?? "") }
    }
    public static func isLocalHost(_ raw: String) -> Bool {
        let h = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h.contains(":") { return h.hasPrefix("fd") || h.hasPrefix("fc") || h.hasPrefix("fe80:") || h == "::1" }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
    private static func addressRank(_ h: String) -> Int { h.hasPrefix("192.168.") ? 0 : h.hasPrefix("10.") ? 1 : h.hasSuffix(".local") ? 2 : 3 }
}
