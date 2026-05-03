import SwiftUI

@main
struct HumanistApp: App {
    var body: some Scene {
        WindowGroup("Humanist") {
            ContentView()
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}
