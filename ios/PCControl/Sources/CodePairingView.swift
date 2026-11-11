import SwiftUI
import RemoteCore

struct CodePairingView: View {
    let pc: NearbyPC
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var requestId: String?
    @State private var endpoint: URL?
    @State private var error: String?
    @State private var busy = false
    @State private var expires = Date.distantPast
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(pc.name,systemImage:"desktopcomputer").font(.headline)
                    Text("Enter the four-digit code that appears on your PC. You only need to do this once.")
                    TextField("4-digit code",text:$code).keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focused).font(.system(size:36,weight:.semibold,design:.monospaced)).multilineTextAlignment(.center)
                        .onChange(of:code) { _,value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
                    Button { Task { await confirm() } } label: { HStack { Spacer(); if busy { ProgressView() }; Text("Connect"); Spacer() } }.disabled(busy || code.count != 4 || requestId == nil)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section { Button("Show a new code on PC") { Task { await start() } }.disabled(busy) }
            }
            .navigationTitle("Connect to PC").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await start() }
        }
    }
    private func send(_ path: String,base:URL,body:[String:String]) async throws -> Data {
        guard let pin = pc.fingerprint, pin.count == 64 else { throw Pairing.ValidationError.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration:configuration,delegate:PinnedSession(fingerprint:pin),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:base.appendingPathComponent(path)); request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        let (data,response) = try await session.data(for:request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else { throw PairFailure(message:String(data:data,encoding:.utf8) ?? "Couldn’t connect to your PC.") }
        return data
    }
    private func start() async {
        busy = true; error = nil; code = ""; requestId = nil
        defer { busy = false }
        guard pc.fingerprint != nil else { error = "Update the PC Control agent to use simple pairing, or scan its setup QR."; return }
        for base in pc.endpoints {
            do {
                let data = try await send("v1/pair/start",base:base,body:[:])
                let reply = try JSONDecoder().decode(StartReply.self,from:data)
                guard reply.deviceId == pc.id else { throw Pairing.ValidationError.invalid }
                requestId = reply.requestId; endpoint = base; expires = Date().addingTimeInterval(Double(reply.expiresIn)); error = nil; focused = true; return
            } catch let failure as PairFailure { error = failure.localizedDescription; return }
            catch { self.error = "Couldn’t reach your PC. Check that both devices are on the same Wi-Fi." }
        }
    }
    private func confirm() async {
        guard let requestId,let endpoint else { return }
        guard Date() < expires else { error = "That code has expired. Tap Show a new code on PC."; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let data = try await send("v1/pair/confirm",base:endpoint,body:["requestId":requestId,"code":code])
            let pairing = try Pairing.parse(data)
            guard pairing.deviceId == pc.id, pairing.certificateSha256 == pc.fingerprint?.lowercased() else { throw Pairing.ValidationError.invalid }
            try model.pair(data:data); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private struct StartReply: Decodable { let requestId: String; let deviceId: String; let expiresIn: Int }
    private struct PairFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
}
