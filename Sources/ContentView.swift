import SwiftUI

struct ContentView: View {
    @StateObject private var server = ServerManager()
    @StateObject private var client = HostClient()
    @StateObject private var updater = UpdateChecker()
    @AppStorage("language") private var language = Lang.system.rawValue
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TransferView(server: server)
                .tabItem { Label { Text(T("tab_transfer")) } icon: { Image(systemName: "arrow.left.arrow.right") } }
                .tag(0)
            ConnectView(server: server, client: client)
                .tabItem { Label { Text(T("tab_connect")) } icon: { Image(systemName: "link") } }
                .tag(1)
            FilesView(server: server)
                .tabItem { Label { Text(T("tab_files")) } icon: { Image(systemName: "folder") } }
                .tag(2)
            SettingsView(server: server, updater: updater)
                .tabItem { Label { Text(T("tab_settings")) } icon: { Image(systemName: "gearshape") } }
                .tag(3)
        }
        .id(language)   // rebuild all screens when the language changes
        .alert(isPresented: $updater.showAlert) {
            Alert(title: Text(T("update_title")),
                  message: Text(TF("update_msg", updater.latestVersion, UpdateChecker.currentVersion)),
                  primaryButton: .default(Text(T("update_open"))) { updater.openRelease() },
                  secondaryButton: .cancel(Text(T("update_later"))))
        }
        .onAppear {
            client.onSaved = { [weak server] in server?.filesVersion += 1 }
            updater.autoCheck()
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
