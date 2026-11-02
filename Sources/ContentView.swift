import SwiftUI

struct ContentView: View {
    @StateObject private var server = ServerManager()

    var body: some View {
        TabView {
            TransferView(server: server)
                .tabItem { Label("Transfer", systemImage: "arrow.left.arrow.right") }
            FilesView(server: server)
                .tabItem { Label("Files", systemImage: "folder") }
            SettingsView(server: server)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
