import SwiftUI
import UniformTypeIdentifiers
import RemoteCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if model.pairing == nil { PairingView() }
            else {
                TabView {
                    ControlView().tabItem { Label("Control",systemImage:"cursorarrow.motionlines") }
                    DisplaysView().tabItem { Label("Displays",systemImage:"display.2") }
                    SettingsView().tabItem { Label("Settings",systemImage:"slider.horizontal.3") }
                }
            }
        }
        .overlay(alignment:.top) {
            if let notice = model.notice {
                Text(notice).font(.subheadline.weight(.medium)).padding(14)
                    .frame(maxWidth:500).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
                    .padding(.horizontal,20).padding(.top,8).shadow(color:.black.opacity(0.1),radius:16,y:5)
                    .onTapGesture { model.notice = nil }.transition(.move(edge:.top).combined(with:.opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }.animation(.easeInOut(duration:0.2),value:model.notice)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing:8) {
            Circle().fill(model.connected ? Color.mint : .orange).frame(width:7,height:7)
            Text(model.preview ? "Preview · Studio PC" : model.connected ? model.computerName : "Connecting to \(model.computerName)…")
                .font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength:4)
            Image(systemName:model.connected ? "wifi" : "wifi.slash").foregroundStyle(.secondary)
        }.padding(.horizontal,14).padding(.vertical,10).background(.thinMaterial,in:Capsule())
            .accessibilityElement(children:.combine).accessibilityIdentifier("connectionStatus")
    }
}

struct ControlView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyboard = false
    @State private var touching = false
    @State private var help = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width > 700
                Group {
                    if geometry.size.height < 530 {
                        ScrollView {
                            VStack(spacing:14) { ConnectionBadge(); trackpad.frame(height:220); clickButtons; HStack(spacing:16) { mediaControls; keyboardButton }; audioControls; if let date = model.shutdownAt { ShutdownBanner(date:date) } }
                        }
                    } else if wide {
                        HStack(spacing:24) {
                            VStack(spacing:16) { ConnectionBadge(); trackpad; clickButtons }
                            VStack(spacing:24) { audioControls; mediaControls; keyboardButton; if let date = model.shutdownAt { ShutdownBanner(date:date) }; Spacer() }.frame(width:250)
                        }
                    } else {
                        VStack(spacing:16) {
                            ConnectionBadge()
                            trackpad
                            clickButtons
                            HStack(spacing:16) { mediaControls; keyboardButton }
                            audioControls
                            if let date = model.shutdownAt { ShutdownBanner(date:date) }
                        }
                    }
                }.padding(.horizontal,20).padding(.top,8).padding(.bottom,16).frame(maxWidth:1100).frame(maxWidth:.infinity)
            }
            .background(Color(uiColor:.systemGroupedBackground))
            .navigationTitle("PC Control")
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { help = true } label: { Image(systemName:"questionmark.circle") }.accessibilityLabel("Trackpad gestures") } }
            .sheet(isPresented:$keyboard) { KeyboardView() }
            .sheet(isPresented:$help) { GestureHelpView() }
            .safeAreaInset(edge:.top,spacing:0) {
                if !model.connected { reconnectBanner }
            }
        }
    }
    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius:28,style:.continuous).fill(Color(uiColor:.secondarySystemGroupedBackground))
            Canvas { context,size in
                let spacing: CGFloat = 22
                for x in stride(from:CGFloat(18),to:size.width,by:spacing) {
                    for y in stride(from:CGFloat(18),to:size.height,by:spacing) {
                        context.fill(Path(ellipseIn:CGRect(x:x,y:y,width:1.5,height:1.5)),with:.color(.secondary.opacity(0.14)))
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius:28)).allowsHitTesting(false)
            VStack(alignment:.leading) {
                HStack {
                    Label("TRACKPAD",systemImage:"cursorarrow").font(.caption.weight(.semibold)).tracking(1.5)
                    Spacer()
                    Circle().fill(touching ? .mint : .clear).frame(width:7,height:7)
                }.foregroundStyle(.secondary)
                Spacer()
                if !touching {
                    VStack(spacing:10) {
                        Image(systemName:"hand.draw").font(.system(size:32,weight:.light)).foregroundStyle(.tertiary)
                        Text("A little space to take control.").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity).transition(.opacity)
                }
                Spacer()
                HStack { Text("Tap to click"); Spacer(); Text("Two fingers to scroll") }.font(.caption).foregroundStyle(.secondary)
            }.padding(22).allowsHitTesting(false)
            Trackpad(touching:$touching)
        }
        .overlay { RoundedRectangle(cornerRadius:28).strokeBorder(touching ? Color.mint.opacity(0.6) : Color.primary.opacity(0.06),lineWidth:1) }
        .frame(minHeight:180,maxHeight:.infinity)
        .animation(.easeOut(duration:0.16),value:touching)
    }
    private var clickButtons: some View {
        HStack(spacing:12) {
            Button { model.click("left") } label: { Label("Left click",systemImage:"computermouse").frame(maxWidth:.infinity,minHeight:44) }
                .accessibilityIdentifier("leftClick")
            Button { model.click("right") } label: { Label("Right click",systemImage:"contextualmenu.and.cursorarrow").frame(maxWidth:.infinity,minHeight:44) }
                .accessibilityIdentifier("rightClick")
        }.font(.subheadline.weight(.medium)).buttonStyle(.bordered).tint(.primary).disabled(!model.connected)
    }
    private var mediaControls: some View {
        HStack(spacing:6) {
            media("backward.end.fill","previous","Previous track")
            media("playpause.fill","playPause","Play or pause")
            media("forward.end.fill","next","Next track")
        }.padding(.horizontal,8).padding(.vertical,3).background(Color(uiColor:.secondarySystemGroupedBackground),in:Capsule())
            .disabled(!model.connected)
    }
    private func media(_ symbol: String,_ key: String,_ label: String) -> some View {
        Button { model.input(.media(key)); model.haptic() } label: { Image(systemName:symbol).font(.system(size:17,weight:.semibold)).frame(minWidth:44,minHeight:44) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
    private var keyboardButton: some View {
        Button { keyboard = true; model.haptic() } label: { Label("Keyboard",systemImage:"keyboard").font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity,minHeight:50) }
            .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(Color(red:0.04,green:0.14,blue:0.12)).disabled(!model.connected).accessibilityIdentifier("keyboardButton")
    }
    private var audioControls: some View {
        HStack(spacing:14) {
            Button { model.toggleMute() } label: { Image(systemName:model.audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size:19)).frame(width:36,height:44) }
                .buttonStyle(.plain).accessibilityLabel(model.audio.muted ? "Unmute PC" : "Mute PC")
            Slider(value:Binding(get:{model.audio.level},set:{model.setVolume($0)}),in:0...100).accessibilityLabel("PC volume").accessibilityValue("\(Int(model.audio.level)) percent")
            Text("\(Int(model.audio.level))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width:30,alignment:.trailing)
        }.padding(.horizontal,16).padding(.vertical,8).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20)).disabled(!model.connected)
    }
    private var reconnectBanner: some View {
        HStack(alignment:.top,spacing:12) {
            ProgressView().padding(.top,3)
            VStack(alignment:.leading,spacing:3) {
                Text("Finding your PC").font(.subheadline.weight(.semibold))
                Text("Keep both devices on the same Wi-Fi and Windows signed in.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            Button("Retry") { model.connection.reconnect() }.font(.subheadline.weight(.semibold))
        }.padding(16).background(.regularMaterial)
    }
}

struct ShutdownBanner: View {
    @EnvironmentObject private var model: AppModel
    let date: Date
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            HStack {
                Image(systemName:"power")
                Text(date > context.date ? "Shutting down in \(Int(ceil(date.timeIntervalSince(context.date))))s" : "Shutdown requested")
                Spacer()
                Button("Cancel") { model.cancelShutdown() }.fontWeight(.semibold)
            }.font(.subheadline).padding(14).background(.orange.opacity(0.12),in:RoundedRectangle(cornerRadius:16))
        }
    }
}

struct DisplaysView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBadge().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                if model.displays.isEmpty {
                    ContentUnavailableView("Displays will appear here",systemImage:"display.2",description:Text("Connect to your PC to adjust each screen’s brightness.")).listRowBackground(Color.clear)
                }
                ForEach(Array(model.displays.enumerated()),id:\.element.id) { index,display in
                    Section {
                        VStack(alignment:.leading,spacing:18) {
                            HStack(spacing:14) {
                                Image(systemName:"display").font(.system(size:26,weight:.light)).foregroundStyle(.mint)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(display.name == "Generic PnP Monitor" ? "Display \(index+1)" : display.name).font(.headline)
                                    if let bounds = display.bounds { Text("\(bounds.width) × \(bounds.height)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if let level = display.brightness { Text("\(Int(level))%").font(.title3.monospacedDigit().weight(.medium)) }
                            }
                            if display.supported, let brightness = display.brightness {
                                HStack { Image(systemName:"sun.min"); Slider(value:Binding(get:{model.displays.first(where:{$0.id == display.id})?.brightness ?? brightness},set:{model.setBrightness(id:display.id,value:$0)}),in:0...100); Image(systemName:"sun.max.fill") }
                                    .foregroundStyle(.secondary).accessibilityLabel("Display \(index+1) brightness").disabled(!model.connected)
                            } else {
                                Label("Brightness isn’t available",systemImage:"info.circle").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical,10)
                    } footer: { if !display.supported { Text("For external screens, enable DDC/CI in the monitor’s menu. Some displays don’t support remote brightness.") } }
                }
                Section { Text("Adjusts your monitor’s actual brightness.").font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear) }
            }.navigationTitle("Displays").refreshable { await model.refresh() }
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { Task { await model.refresh() } } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh displays").disabled(!model.connected || model.isRefreshing) } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var shutdown = false
    @State private var forget = false
    @State private var lock = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Your computer") {
                    LabeledContent { Text(model.computerName).foregroundStyle(.secondary) } label: { Label("Paired PC",systemImage:"desktopcomputer") }
                    LabeledContent("Connection",value:model.connected ? "Connected" : "Reconnecting")
                    if let host = model.connection.endpoint?.host ?? model.pairing?.endpoints.first?.host { LabeledContent("Local address",value:host) }
                }
                Section("Trackpad") {
                    VStack(alignment:.leading) { HStack { Text("Pointer speed"); Spacer(); Text(String(format:"%.1f×",model.pointerSpeed)).foregroundStyle(.secondary).monospacedDigit() }; Slider(value:$model.pointerSpeed,in:0.5...3,step:0.1).accessibilityLabel("Pointer speed") }.padding(.vertical,4)
                    Toggle("Natural scrolling",isOn:$model.naturalScrolling)
                    Toggle("Haptic clicks",isOn:$model.hapticClicks)
                    NavigationLink { GestureHelpContent().navigationTitle("Trackpad gestures").navigationBarTitleDisplayMode(.inline) } label: { Label("Trackpad gestures",systemImage:"hand.draw") }
                }
                Section {
                    Button { lock = true } label: { Label("Lock PC",systemImage:"lock") }.disabled(!model.connected || model.preview)
                    Button(role:.destructive) { shutdown = true } label: { Label("Shut down PC",systemImage:"power") }.disabled(!model.connected || model.preview)
                } header: { Text("Power") } footer: { Text("Shutdown has a 30-second countdown you can cancel.") }
                Section("Pairing") {
                    if let p = model.pairing {
                        LabeledContent("Secure connection",value:"Certificate pinned")
                        DisclosureGroup("PC identity") { Text(p.certificateSha256).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    Button("Forget this PC",role:.destructive) { forget = true }
                }
                Section {
                    LabeledContent("Version",value:"1.0")
                    NavigationLink("Privacy") { PrivacyView() }
                    Link("Help & support",destination:URL(string:"https://github.com/stormey2010/pc-control/blob/main/ios/README.md")!)
                } footer: { Text("A quiet remote. Everything stays on your local network.") }
            }.navigationTitle("Settings")
                .confirmationDialog("Shut down \(model.computerName)?",isPresented:$shutdown,titleVisibility:.visible) { Button("Shut down in 30 seconds",role:.destructive) { model.shutdown() } } message: { Text("Save your work first. You can cancel the countdown in the app.") }
                .confirmationDialog("Lock \(model.computerName)?",isPresented:$lock,titleVisibility:.visible) { Button("Lock PC") { model.lock() } } message: { Text("You’ll need to unlock Windows at your computer before using the trackpad again.") }
                .confirmationDialog("Forget this PC?",isPresented:$forget,titleVisibility:.visible) { Button("Forget PC",role:.destructive) { model.forget() } } message: { Text("You’ll need to scan your PC’s setup code to connect again.") }
        }
    }
}

struct GestureHelpContent: View {
    var body: some View {
        List {
            gesture("Move the pointer","One finger glides across the trackpad.","cursorarrow.motionlines")
            gesture("Click","Tap once. Tap twice to double-click.","hand.tap")
            gesture("Right-click","Tap with two fingers, or use the Right click button.","hand.tap.fill")
            gesture("Scroll","Slide two fingers in any direction.","hand.draw")
            gesture("Drag","Hold one finger still briefly, then move it. Lift to release.","hand.point.up.left")
            gesture("Type","Open Keyboard, then type into the selected field on your PC.","keyboard")
        }
    }
    private func gesture(_ title: String,_ detail: String,_ icon: String) -> some View { HStack(alignment:.top,spacing:16) { Image(systemName:icon).font(.title2).foregroundStyle(.mint).frame(width:32); VStack(alignment:.leading,spacing:6) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary) } }.padding(.vertical,10) }
}
struct GestureHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { GestureHelpContent().navigationTitle("Make yourself comfortable").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } } }.presentationDragIndicator(.visible) }
}
struct PrivacyView: View {
    var body: some View {
        List {
            Section("Your PC. Your network.") { Text("Commands travel directly between this iPhone and your paired PC using an encrypted connection. No account, cloud relay, advertising, or analytics is used.") }
            Section("Stored on your iPhone") { Text("Your private pairing key is stored in iOS Keychain on this device. Pointer and display preferences are saved locally. Typed text is sent to your PC and isn’t saved by the app.") }
            Section("Permissions") { Text("Local network access finds and controls your PC. Camera access is optional and only scans the setup code. You can import the setup file instead.") }
        }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
}

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scan = false
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:28) {
                    Spacer(minLength:20)
                    ZStack {
                        RoundedRectangle(cornerRadius:32).fill(.mint.opacity(0.12)).frame(width:108,height:108)
                        Image(systemName:"cursorarrow.motionlines").font(.system(size:48,weight:.medium)).foregroundStyle(.mint)
                    }.accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:14) {
                        Text("Your PC.\nA touch away.").font(.system(size:42,weight:.bold,design:.rounded)).tracking(-1)
                        Text("A smooth trackpad, a familiar keyboard, and the controls you reach for. Right on your iPhone.").font(.title3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    NearbyList(discovery:model.discovery)
                    DisclosureGroup("Other ways to connect") { VStack(spacing:12) {
                        Button { scan = true } label: { Label("Scan PC setup code",systemImage:"qrcode.viewfinder").fontWeight(.semibold).frame(maxWidth:.infinity,minHeight:48) }.buttonStyle(.borderedProminent).foregroundStyle(Color(red:0.04,green:0.14,blue:0.12)).accessibilityIdentifier("scanSetup")
                        Button { importing = true } label: { Label("Import setup file",systemImage:"doc.badge.plus").frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.bordered).accessibilityIdentifier("importSetup")
                    }
                    }
                    HStack(alignment:.top,spacing:12) { Image(systemName:"lock.shield").foregroundStyle(.mint); Text("Paired privately. Connected directly over your Wi-Fi. No account needed.").font(.subheadline).foregroundStyle(.secondary) }
                    DisclosureGroup("Where’s my setup code?") {
                        Text("Open PC Control’s setup code on your Windows computer, then scan it here. Keep your phone and PC on the same Wi-Fi. You can also transfer and import the private connection.json setup file.").font(.subheadline).foregroundStyle(.secondary).padding(.top,8)
                    }.font(.subheadline)
                }.padding(28).frame(maxWidth:550).frame(maxWidth:.infinity)
            }.background(Color(uiColor:.systemGroupedBackground))
                .sheet(isPresented:$scan) { NavigationStack { ScannerView(onCode:{ value in scan = false; pair(Data(value.utf8)) },onFailure:{ value in scan = false; error = value }).ignoresSafeArea(edges:.bottom).overlay(alignment:.bottom) { Text("Point your camera at the setup code on your PC").font(.subheadline.weight(.medium)).padding(20).background(.ultraThinMaterial,in:Capsule()).padding(24) }.navigationTitle("Pair your PC").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { scan = false } } } } }
                .fileImporter(isPresented:$importing,allowedContentTypes:[.json,.plainText],allowsMultipleSelection:false) { result in
                    do { guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let values = try url.resourceValues(forKeys:[.fileSizeKey]); guard (values.fileSize ?? 0) <= 16384 else { throw Pairing.ValidationError.tooLarge }; pair(try Data(contentsOf:url)) }
                    catch { self.error = error.localizedDescription }
                }
                .alert("Couldn’t pair this PC",isPresented:Binding(get:{error != nil},set:{if !$0 { error = nil }})) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func pair(_ data: Data) { do { try model.pair(data:data) } catch { self.error = error.localizedDescription } }
}
private struct NearbyList: View {
    @State private var selected: NearbyPC?
    @ObservedObject var discovery: Discovery
    var body: some View {
        if !discovery.computers.isEmpty {
            VStack(alignment:.leading,spacing:10) {
                Text("NEARBY COMPUTERS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1.2)
                ForEach(discovery.computers) { pc in Button { selected = pc } label: { HStack { Image(systemName:"desktopcomputer").foregroundStyle(.mint); Text(pc.name).fontWeight(.medium); Spacer(); Text("Connect").font(.caption).foregroundStyle(.secondary) }.padding(14).background(.background,in:RoundedRectangle(cornerRadius:16)) }.buttonStyle(.plain) }
            }.sheet(item:$selected) { pc in CodePairingView(pc:pc) }
        } else {
            HStack { ProgressView(); Text("Looking for PCs on your network...").foregroundStyle(.secondary) }.padding(.vertical)
        }
    }
}
