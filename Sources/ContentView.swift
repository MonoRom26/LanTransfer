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

// Button styles that work on iOS 14+ (borderedProminent needs iOS 15)
struct FilledButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .cornerRadius(10)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground).opacity(configuration.isPressed ? 0.6 : 1))
            .cornerRadius(8)
    }
}
