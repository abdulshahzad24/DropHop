import SwiftUI

@main
struct DropHopMobileApp: App {
    @StateObject private var client = SyncClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
        }
    }
}
