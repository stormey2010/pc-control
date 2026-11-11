import SwiftUI

@main struct PCControlApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(.mint)
                .onChange(of:scenePhase) { _, phase in if phase == .active { model.activate() } else { model.deactivate() } }
                .task { model.activate() }
        }
    }
}
