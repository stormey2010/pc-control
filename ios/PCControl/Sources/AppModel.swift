import SwiftUI
import Combine
import RemoteCore

@MainActor final class AppModel: ObservableObject {
    let connection = RemoteConnection()
    let discovery = Discovery()
    @Published private(set) var pairing: Pairing?
    @Published var audio = AudioState(level:0,muted:false)
    @Published var displays: [DisplayState] = []
    @Published var notice: String?
    @Published var shutdownAt: Date?
    @Published var isRefreshing = false
    @Published var preview = false
    @Published var pointerSpeed = UserDefaults.standard.object(forKey:"pointerSpeed") as? Double ?? 1.3 { didSet { UserDefaults.standard.set(pointerSpeed,forKey:"pointerSpeed") } }
    @Published var naturalScrolling = UserDefaults.standard.object(forKey:"naturalScrolling") as? Bool ?? true { didSet { UserDefaults.standard.set(naturalScrolling,forKey:"naturalScrolling") } }
    @Published var hapticClicks = UserDefaults.standard.object(forKey:"hapticClicks") as? Bool ?? true { didSet { UserDefaults.standard.set(hapticClicks,forKey:"hapticClicks") } }
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingAudio: AudioState?
    private var audioPump: Task<Void,Never>?
    private var pendingBrightness: [String:Double] = [:]
    private var brightnessPumps: [String:Task<Void,Never>] = [:]
    private var noticeTask: Task<Void,Never>?
    var connected: Bool { preview || connection.connected }
    var computerName: String { connection.info?.name ?? pairing?.name ?? "Your PC" }
    init() {
        connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&subscriptions)
        discovery.$computers.sink { [weak self] pcs in
            guard let self, let p = self.pairing, let pc = pcs.first(where:{$0.id == p.deviceId}) else { return }
            self.connection.updateDiscovery(pc.endpoints)
        }.store(in:&subscriptions)
        connection.onReady = { [weak self] in Task { await self?.refresh() } }
        connection.onError = { [weak self] in self?.show($0) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            preview = true
            pairing = Pairing(deviceId:"preview",name:"Studio PC",port:48180,urls:["https://192.168.4.62:48180"],token:String(repeating:"x",count:43),certificateSha256:String(repeating:"0",count:64))
            audio = AudioState(level:34,muted:false)
            displays = [.init(id:"display1",name:"Display 1",brightness:72),.init(id:"display2",name:"Display 2",brightness:58)]
            return
        }
        #endif
        do { pairing = try KeychainStore.load(); connection.configure(pairing) }
        catch { notice = error.localizedDescription }
    }
    func activate() { guard !preview else { return }; discovery.start(); connection.activate() }
    func deactivate() {
        guard !preview else { return }
        audioPump?.cancel(); audioPump = nil; pendingAudio = nil
        brightnessPumps.values.forEach { $0.cancel() }; brightnessPumps = [:]; pendingBrightness = [:]
        connection.deactivate(); discovery.stop()
    }
    func pair(data: Data) throws { let p = try Pairing.parse(data); try KeychainStore.save(p); pairing = p; displays = []; connection.configure(p); connection.activate(); discovery.start() }
    func forget() {
        do { try KeychainStore.delete(); connection.configure(nil); pairing = nil; displays = []; shutdownAt = nil }
        catch { show(error.localizedDescription) }
    }
    func show(_ text: String) { noticeTask?.cancel(); notice = text; noticeTask = Task { [weak self] in try? await Task.sleep(for:.seconds(5)); guard !Task.isCancelled else { return }; self?.notice = nil } }
    func refresh() async {
        guard connected, !preview, !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        async let a = connection.perform(Command("audio.get"))
        async let d = connection.perform(Command("displays.list"))
        async let s = connection.perform(Command("system.status"))
        do {
            let (av,dv,sv) = try await (a,d,s)
            if audioPump == nil { audio = try av.decode(AudioState.self) }
            if brightnessPumps.isEmpty { displays = try dv.decode([DisplayState].self) }
            shutdownAt = sv["shutdownPending"]?.boolValue == true ? parseDate(sv["scheduledAt"]?.stringValue) : nil
        } catch { if connection.connected { show(error.localizedDescription) } }
    }
    func setVolume(_ value: Double) { audio.level = value; scheduleAudio() }
    func toggleMute() { audio.muted.toggle(); haptic(); scheduleAudio() }
    private func scheduleAudio() {
        guard !preview else { return }; guard connected else { return }
        pendingAudio = audio
        guard audioPump == nil else { return }
        audioPump = Task { [weak self] in
            guard let self else { return }; defer { self.audioPump = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(50)); guard !Task.isCancelled, let desired = self.pendingAudio else { return }
                self.pendingAudio = nil
                var c = Command.volume(desired.level); c.muted = desired.muted
                do { let r = try await self.connection.perform(c); if !Task.isCancelled && self.pendingAudio == nil { self.audio = try r.decode(AudioState.self) } }
                catch { if !Task.isCancelled { self.show(error.localizedDescription) }; return }
                if self.pendingAudio == nil { return }
            }
        }
    }
    func setBrightness(id: String,value: Double) {
        if let i = displays.firstIndex(where:{$0.id == id}) { displays[i].brightness = value }
        guard !preview, connected else { return }
        pendingBrightness[id] = value
        guard brightnessPumps[id] == nil else { return }
        brightnessPumps[id] = Task { [weak self] in
            guard let self else { return }; defer { self.brightnessPumps[id] = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(100)); guard !Task.isCancelled, let value = self.pendingBrightness.removeValue(forKey:id) else { return }
                do { _ = try await self.connection.perform(.brightness(id,value)) }
                catch { if !Task.isCancelled { self.show(error.localizedDescription) }; return }
                if self.pendingBrightness[id] == nil { return }
            }
        }
    }
    func input(_ c: Command) { guard !preview else { return }; connection.input(c) }
    func click(_ button: String) { input(.button(button)); haptic() }
    func drag(_ held: Bool) { input(.button("left",held ? "down" : "up")); connection.setDragging(held); if held { haptic() } }
    func release() { guard !preview else { return }; connection.releaseInput() }
    func haptic() { if hapticClicks { UIImpactFeedbackGenerator(style:.light).impactOccurred() } }
    func shutdown() { Task { do { let r = try await connection.perform(.shutdown()); shutdownAt = parseDate(r["scheduledAt"]?.stringValue) ?? Date().addingTimeInterval(30); haptic() } catch { show(error.localizedDescription) } } }
    func cancelShutdown() { Task { do { _ = try await connection.perform(Command("system.cancelShutdown")); shutdownAt = nil } catch { show(error.localizedDescription) } } }
    func lock() { Task { do { _ = try await connection.perform(Command("system.lock")); show("Your PC is locked.") } catch { show(error.localizedDescription) } } }
    private func parseDate(_ value: String?) -> Date? { guard let value else { return nil }; let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.date(from:value) ?? ISO8601DateFormatter().date(from:value) }
}
