import SwiftUI

struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @AppStorage("port") private var port = 8080
    @AppStorage("usePassword") private var usePassword = false
    @AppStorage("password") private var password = ""
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("bonjour") private var bonjour = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Stepper("Port: \(port)", value: $port, in: 1024...65535)
                    Toggle("Keep screen awake", isOn: $keepAwake)
                    Toggle("Bonjour name (LanTransfer.local)", isOn: $bonjour)
                }
                Section {
                    Toggle("Require password", isOn: $usePassword)
                    if usePassword {
                        LabeledContent("Username", value: "admin")
                        SecureField("Password", text: $password)
                    }
                } header: { Text("Security") }
                  footer: { Text("Your PC browser will ask for the username and password.") }

                Section("Storage") {
                    LabeledContent("Folder", value: "On My iPhone › LanTransfer")
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

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    Text("Both devices must be on the same Wi-Fi. Transfers are not encrypted, so use a trusted network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
