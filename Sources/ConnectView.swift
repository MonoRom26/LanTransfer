import SwiftUI
import UniformTypeIdentifiers

struct ConnectView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var client: HostClient
    @StateObject private var discovery = Discovery()
    @State private var address = ""
    @State private var password = ""
    @State private var showScanner = false
    @State private var showImporter = false

    private var peers: [Discovery.Peer] {
        let me = ServerManager.wifiIPAddress()
        return discovery.peers.filter { $0.host != me }
    }

    var body: some View {
        NavigationView {
            Group {
                if client.isConnected { connectedList } else { connectList }
            }
            .navigationTitle(client.isConnected ? client.hostName : T("tab_connect"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if client.isConnected {
                        Button(action: { client.refresh() }) { Image(systemName: "arrow.clockwise") }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if client.isConnected {
                        Button(action: { client.disconnect() }) {
                            Text(T("disconnect")).foregroundColor(.red)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showScanner) {
            ScannerSheet { code in
                showScanner = false
                client.connect(address: code, name: "", password: password)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    // MARK: not connected
    private var connectList: some View {
        List {
            Section(header: Text(T("nearby"))) {
                if peers.isEmpty {
                    Text(T("none_found")).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(peers) { p in
                    Button(action: {
                        client.connect(address: "\(p.host):\(p.port)", name: p.name, password: password)
                    }) {
                        HStack {
                            Image(systemName: "iphone").foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundColor(.primary)
                                Text("\(p.host):\(p.port)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                    .disabled(client.isConnecting)
                }
            }

            Section(header: Text(T("other_ways"))) {
                Button(action: { showScanner = true }) {
                    Label { Text(T("scan_qr")) } icon: { Image(systemName: "qrcode.viewfinder") }
                }
                TextField(T("address"), text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                SecureField(T("password_optional"), text: $password)
                Button(action: {
                    client.connect(address: address, name: "", password: password)
                }) {
                    HStack {
                        Text(client.isConnecting ? T("connecting") : T("connect"))
                        if client.isConnecting { ProgressView() }
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || client.isConnecting)
            }

            if let key = client.errorKey {
                Section {
                    Text(T(key)).font(.footnote).foregroundColor(.red)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    // MARK: connected
    private var connectedList: some View {
        List {
            Section {
                HStack {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(T("connected"))
                    Spacer()
                    Text(client.hostAddress).font(.caption).foregroundColor(.secondary)
                }
                Button(action: { showImporter = true }) {
                    Label { Text(T("send_files")) } icon: { Image(systemName: "square.and.arrow.up") }
                }
            }

            Section(header: Text(TF("files_on_host", client.hostName))) {
                if client.files.isEmpty {
                    Text(T("no_files")).foregroundColor(.secondary)
                }
                ForEach(client.files) { f in
                    HStack {
                        Image(systemName: "doc").foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(f.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { client.download(f) }) {
                            Image(systemName: "arrow.down.circle").font(.title3)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            }

            if !client.transfers.isEmpty {
                Section(header: Text(T("activity"))) {
                    ForEach(client.transfers) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: t.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                                Text(t.name).lineLimit(1)
                                Spacer()
                                Text(stateText(t)).font(.caption).foregroundColor(stateColor(t))
                            }
                            if t.state == .running {
                                ProgressView(value: t.progress)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { client.upload(urls: urls) }
        }
    }

    private func stateText(_ t: TransferItem) -> String {
        switch t.state {
        case .running: return "\(Int(t.progress * 100))%"
        case .done: return T("done")
        case .failed: return T("failed")
        }
    }

    private func stateColor(_ t: TransferItem) -> Color {
        switch t.state {
        case .running: return .secondary
        case .done: return .green
        case .failed: return .red
        }
    }
}

struct ScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.presentationMode) private var presentation
    @State private var denied = false

    var body: some View {
        NavigationView {
            ZStack {
                QRScannerView(onCode: onCode, onDenied: { denied = true })
                    .edgesIgnoringSafeArea(.all)
                VStack {
                    Spacer()
                    Text(denied ? T("camera_denied") : T("scan_hint"))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 30)
                }
            }
            .navigationTitle(T("scan_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { presentation.wrappedValue.dismiss() }) { Text(T("cancel")) }
                }
            }
        }
    }
}
