import SwiftUI

@main
struct GeminiOCRScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Lock to portrait per requirements. Also set this in
                // Project Settings -> General -> Deployment Info -> Device Orientation.
                .statusBarHidden(true)
        }
    }
}
