import SwiftUI

struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @AppStorage("port") private var port = 8080
    @AppStorage("usePassword") private var usePassword = false
    @AppStorage("password") private var password = ""
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("bonjour") private var bonjour = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server")) {
                    Stepper("Port: \(port)", value: $port, in: 1024...65535)
                    Toggle("Keep screen awake", isOn: $keepAwake)
                    Toggle("Bonjour name (LanTransfer.local)", isOn: $bonjour)
                }

                Section(header: Text("Security"),
                        footer: Text("Your PC browser will ask for the username and password.")) {
                    Toggle("Require password", isOn: $usePassword)
                    if usePassword {
                        HStack {
                            Text("Username")
                            Spacer()
                            Text("admin").foregroundColor(.secondary)
                        }
                        SecureField("Password", text: $password)
                    }
                }

                Section(header: Text("Storage")) {
                    HStack {
                        Text("Folder")
                        Spacer()
                        Text("On My iPhone › LanTransfer").foregroundColor(.secondary)
                    }
                    Button("Open Files app") {
                        if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
                    }
                }

                if server.isRunning {
                    Section {
                        Label("Stop and start the server to apply changes.", systemImage: "info.circle")
                            .font(.footnote)
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0").foregroundColor(.secondary)
                    }
                    Text("Both devices must be on the same Wi-Fi. Transfers are not encrypted, so use a trusted network.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
