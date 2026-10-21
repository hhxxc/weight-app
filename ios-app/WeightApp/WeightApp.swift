import SwiftUI

@main
struct WeightApp: App {
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}
