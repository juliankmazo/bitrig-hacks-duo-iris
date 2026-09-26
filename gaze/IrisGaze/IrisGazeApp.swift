import SwiftUI

@main
struct IrisGazeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = GazeModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.light)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.resumePredictions() }
                    else { model.pausePredictions() }
                }
        }
    }
}
