import SwiftUI

@main
struct SportCamApp: App {
    @StateObject private var engine = CameraEngine()

    var body: some Scene {
        WindowGroup {
            OsmoScreen(engine: engine)
                .preferredColorScheme(.dark)
        }
    }
}
