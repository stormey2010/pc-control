import Foundation
import Combine
import RemoteCore
import Darwin

struct NearbyPC: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoints: [URL]
    let fingerprint: String?
}

@MainActor final class Discovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var computers: [NearbyPC] = []
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var found: [String:NearbyPC] = [:]
    func start() {
        guard browser == nil else { return }
        let b = NetServiceBrowser(); b.delegate = self; browser = b
        b.searchForServices(ofType:"_pccontrol._tcp.",inDomain:"local.")
    }
    func stop() { browser?.stop(); browser = nil; resolving.forEach { $0.stop() }; resolving = []; found = [:]; computers = [] }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.append(service); service.delegate = self; service.resolve(withTimeout:5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let p = record(service) { found.removeValue(forKey:p.id) }; publish()
        resolving.removeAll { $0 == service }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        if let p = record(sender) { found[p.id] = p; publish() }
    }
    private func publish() { computers = found.values.sorted { $0.name < $1.name } }
    private func record(_ service: NetService) -> NearbyPC? {
        guard let data = service.txtRecordData() else { return nil }
        let txt = NetService.dictionary(fromTXTRecord:data)
        guard let idData = txt["id"], let id = String(data:idData,encoding:.utf8), txt["tls"] == Data("1".utf8), (1024...65535).contains(service.port) else { return nil }
        var urls: [URL] = []
        for address in service.addresses ?? [] {
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            let result = address.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return getnameinfo(base.assumingMemoryBound(to:sockaddr.self),socklen_t(address.count),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)
            }
            let name = String(cString:host)
            guard result == 0, Pairing.isLocalHost(name), name != "127.0.0.1", name != "::1" else { continue }
            var c = URLComponents(); c.scheme = "https"; c.host = name; c.port = service.port
            if let u = c.url { urls.append(u) }
        }
        urls.sort { ($0.host?.hasPrefix("192.168.") == true ? 0 : 1) < ($1.host?.hasPrefix("192.168.") == true ? 0 : 1) }
        let suffix = "-" + String(id.prefix(8))
        let name = service.name.hasSuffix(suffix) ? String(service.name.dropLast(suffix.count)) : service.name
        return NearbyPC(id:id,name:name,endpoints:urls,fingerprint:txt["pin"].flatMap { String(data:$0,encoding:.utf8) })
    }
}
