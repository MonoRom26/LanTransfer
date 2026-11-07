import SwiftUI

struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @AppStorage("language") private var language = Lang.system.rawValue
    @AppStorage("port") private var port = 8080
    @AppStorage("usePassword") private var usePassword = false
    @AppStorage("password") private var password = ""
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("discoverable") private var discoverable = true

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(T("language"))) {
                    ForEach(Lang.allCases) { l in
                        Button(action: { language = l.rawValue }) {
                            HStack {
                                Text(l.nativeName).foregroundColor(.primary)
                                Spacer()
                                if language == l.rawValue {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section(header: Text(T("sec_server"))) {
                    Stepper(value: $port, in: 1024...65535) { Text(TF("port", port)) }
                    Toggle(isOn: $keepAwake) { Text(T("keep_awake")) }
                    Toggle(isOn: $discoverable) { Text(T("discoverable")) }
                }

                Section(header: Text(T("security")), footer: Text(T("pw_footer"))) {
                    Toggle(isOn: $usePassword) { Text(T("require_password")) }
                    if usePassword {
                        HStack {
                            Text(T("username"))
                            Spacer()
                            Text("admin").foregroundColor(.secondary)
                        }
                        SecureField(T("password"), text: $password)
                    }
                }

                Section(header: Text(T("storage"))) {
                    HStack {
                        Text(T("folder"))
                        Spacer()
                        Text(T("folder_path")).foregroundColor(.secondary).font(.footnote)
                    }
                    Button(action: {
                        if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
                    }) { Text(T("open_files_app")) }
                }

                if server.isRunning {
                    Section {
                        Text(T("restart_note")).font(.footnote)
                    }
                }

                Section(header: Text(T("about"))) {
                    HStack {
                        Text(T("version"))
                        Spacer()
                        Text("1.1").foregroundColor(.secondary)
                    }
                    Text(T("about_text"))
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle(T("tab_settings"))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
