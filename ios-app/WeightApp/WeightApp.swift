import SwiftUI

@main
struct WeightApp: App {
    @ObservedObject private var state = AppState.shared

    init() {
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .background(Theme.canvas.ignoresSafeArea())
        }
    }
}
