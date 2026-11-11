import Foundation
import Combine
import RemoteCore

@MainActor final class RemoteConnection: ObservableObject {
    enum State: Equatable { case offline, connecting, connected, waiting(String) }
    @Published private(set) var state: State = .offline
    @Published private(set) var info: DeviceInfo?
    @Published private(set) var endpoint: URL?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    private var pairing: Pairing?
    private var discovered: [URL] = []
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void,Never>?
    private var heartbeat: Task<Void,Never>?
    private var sendTask: Task<Void,Never>?
    private var lease: Task<Void,Never>?
    private var generation = UUID()
    private var active = false
    private var counter = 0
    private var queue = InputQueue()
    private struct Pending { let continuation: CheckedContinuation<JSONValue,Error>; let timeout: Task<Void,Never> }
    private var pending: [Int:Pending] = [:]
    var connected: Bool { state == .connected }
    enum Failure: LocalizedError { case disconnected, timeout, overloaded, identity
        var errorDescription: String? { switch self {
        case .disconnected:return "Your PC is disconnected. Keep both devices on the same Wi-Fi and make sure Windows is signed in."
        case .timeout:return "Your PC didn’t respond. Reconnecting…"
        case .overloaded:return "The network is falling behind. Reconnecting to clear old input."
        case .identity:return "This PC’s identity doesn’t match its setup code. Pair again using a fresh code from your PC."
        } }
    }
    func configure(_ p: Pairing?) { disconnect(); pairing = p; discovered = []; if active { reconnect() } }
    func updateDiscovery(_ urls: [URL]) { discovered = urls; if active && !connected && connectionTask == nil { reconnect() } }
    func activate() { active = true; if connectionTask == nil { reconnect() } }
    func deactivate() {
        active = false
        let old = socket
        let oldSession = session
        socket = nil; session = nil
        disconnect()
        // Best effort only: the server's two-second lease also releases input
        // if iOS suspends us before this final message reaches the wire.
        if let old { Task {
            let deadline = Task { try? await Task.sleep(for:.milliseconds(300)); if !Task.isCancelled { old.cancel(with:.goingAway,reason:nil); oldSession?.invalidateAndCancel() } }
            try? await old.send(.data(try JSONEncoder().encode(Command("input.release"))))
            deadline.cancel(); old.cancel(with:.goingAway,reason:nil); oldSession?.invalidateAndCancel()
        } } else { oldSession?.invalidateAndCancel() }
    }
    private func disconnect() {
        generation = UUID(); connectionTask?.cancel(); connectionTask = nil
        heartbeat?.cancel(); heartbeat = nil; lease?.cancel(); lease = nil
        sendTask?.cancel(); sendTask = nil; queue.clear()
        socket?.cancel(with:.goingAway,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        state = .offline; info = nil
        failPending(Failure.disconnected)
    }
    private func failPending(_ error: Error) { let all = pending; pending.removeAll(); for p in all.values { p.timeout.cancel(); p.continuation.resume(throwing:error) } }
    func reconnect() {
        guard active, let p = pairing else { return }
        disconnect(); let current = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled && self.active && self.generation == current {
                self.state = .connecting
                var seen = Set<URL>()
                let urls = (self.discovered+p.endpoints).filter { seen.insert($0).inserted }
                var last: Error = Failure.disconnected
                for base in urls {
                    guard !Task.isCancelled, self.generation == current else { return }
                    do { try await self.run(base:base,pairing:p,generation:current); last = Failure.disconnected }
                    catch { last = error }
                    guard self.generation == current else { return }
                    self.cleanSocket(error:last)
                    if Task.isCancelled || self.generation != current { return }
                }
                let message: String
                if let code = last as? URLError, code.code == .serverCertificateUntrusted || code.code == .secureConnectionFailed { message = "Check your PC’s setup code and secure connection." }
                else { message = last.localizedDescription }
                self.state = .waiting(message)
                attempt = min(attempt+1,5)
                let delay = min(pow(2,Double(attempt-1))*0.5,10) + Double.random(in:0...0.25)
                try? await Task.sleep(for:.seconds(delay))
            }
        }
    }
    private func cleanSocket(error: Error) {
        state = .connecting; info = nil
        heartbeat?.cancel(); heartbeat = nil; lease?.cancel(); lease = nil
        sendTask?.cancel(); sendTask = nil; queue.clear(); socket?.cancel(with:.goingAway,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil; failPending(error)
    }
    private func run(base: URL,pairing p: Pairing,generation current: UUID) async throws {
        var components = URLComponents(url:base,resolvingAgainstBaseURL:false)!
        components.scheme = "wss"; components.path = "/v1/ws"
        var request = URLRequest(url:components.url!); request.timeoutInterval = 8
        request.setValue("Bearer \(p.token)",forHTTPHeaderField:"Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false; configuration.timeoutIntervalForRequest = 8
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration:configuration,delegate:PinnedSession(fingerprint:p.certificateSha256),delegateQueue:nil)
        self.session = session
        let ws = session.webSocketTask(with:request); ws.maximumMessageSize = 65536
        socket = ws; endpoint = base; ws.resume()
        // A peer that accepts TCP but never sends a WebSocket ready event must
        // not leave the app connecting indefinitely.
        let handshake = Task { try? await Task.sleep(for:.seconds(10)); if !Task.isCancelled { ws.cancel(with:.goingAway,reason:nil) } }
        defer { handshake.cancel() }
        while !Task.isCancelled && generation == current {
            let message = try await ws.receive()
            guard generation == current else { return }
            let data: Data
            switch message { case .data(let v):data = v; case .string(let v):data = Data(v.utf8); @unknown default:continue }
            let reply = try JSONDecoder().decode(Reply.self,from:data)
            if reply.event == "ready", let info = reply.info {
                guard info.deviceId == p.deviceId, info.protocolVersion == 1 else { throw Failure.identity }
                handshake.cancel(); self.info = info; state = .connected
                heartbeat = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for:.seconds(15)); guard !Task.isCancelled, let self else { return }; do { _ = try await self.perform(Command("ping")) } catch { self.socket?.cancel(with:.goingAway,reason:nil); return } } }
                onReady?()
            } else if let id = reply.id, let p = pending.removeValue(forKey:id) {
                p.timeout.cancel()
                if reply.ok == true { p.continuation.resume(returning:reply.result ?? .null) }
                else if let error = reply.error { p.continuation.resume(throwing:error) }
                else { p.continuation.resume(throwing:Failure.disconnected) }
            } else if let error = reply.error { onError?(error.message) }
        }
    }
    func perform(_ command: Command) async throws -> JSONValue {
        guard connected else { throw Failure.disconnected }
        counter += 1; let id = counter; var command = command; command.id = id
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for:.seconds(12)); guard !Task.isCancelled, let self, let p = self.pending.removeValue(forKey:id) else { return }
                p.continuation.resume(throwing:Failure.timeout)
                self.socket?.cancel(with:.goingAway,reason:nil)
            }
            pending[id] = Pending(continuation:continuation,timeout:timeout)
            if !queue.append(command) { pending.removeValue(forKey:id); timeout.cancel(); continuation.resume(throwing:Failure.overloaded); socket?.cancel(with:.goingAway,reason:nil); return }
            drain()
        }
    }
    func input(_ command: Command) {
        guard connected else { return }
        if !queue.append(command) { socket?.cancel(with:.goingAway,reason:nil); onError?(Failure.overloaded.localizedDescription); return }
        drain()
    }
    private func drain() {
        guard sendTask == nil, let ws = socket, connected else { return }
        let current = generation
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.sendTask = nil } }
            while !Task.isCancelled, self.generation == current, let c = self.queue.popFirst() {
                do { try await ws.send(.data(try JSONEncoder().encode(c))) }
                catch { ws.cancel(with:.goingAway,reason:nil); return }
            }
        }
    }
    func setDragging(_ held: Bool) {
        lease?.cancel(); lease = nil
        if held { lease = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for:.milliseconds(500)); guard !Task.isCancelled else { return }; self?.input(Command("input.keepAlive")) } } }
    }
    func releaseInput() { setDragging(false); input(Command("input.release")) }
}
