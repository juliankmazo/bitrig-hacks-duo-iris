import SwiftUI

@main
struct IrisGazeApp: App {
    @State private var model = GazeModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.light)
                .task { model.start() }
        }
    }
}
