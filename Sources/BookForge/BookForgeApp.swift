import SwiftUI

@main
struct BookForgeApp: App {
    var body: some Scene {
        WindowGroup("BookForge") {
            ContentView()
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}
