import SwiftUI
import CoreImage.CIFilterBuiltins

struct TransferView: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    if server.isRunning {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text(T("ready")).font(.footnote).foregroundColor(.green)
                        }
                        if let qr = qrImage(for: server.urlString) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 190, height: 190)
                        }
                        Text(T("open_on_pc"))
                            .font(.footnote).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Text(server.urlString)
                            .font(.system(.title3, design: .monospaced))
                        Button(action: { UIPasteboard.general.string = server.urlString }) {
                            Label { Text(T("copy_address")) } icon: { Image(systemName: "doc.on.doc") }
                        }
                        .buttonStyle(OutlineButtonStyle())
                    } else {
                        Image(systemName: "wifi")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                        Text(T("server_stopped"))
                    }

                    if !server.errorText.isEmpty {
                        Text(server.errorText).font(.footnote).foregroundColor(.red)
                    }

                    Button(action: { server.isRunning ? server.stop() : server.start() }) {
                        Text(server.isRunning ? T("stop_server") : T("start_server"))
                    }
                    .buttonStyle(FilledButtonStyle(color: server.isRunning ? .red : .blue))

                    if !server.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(T("activity")).font(.headline)
                            ForEach(server.activity) { item in
                                HStack {
                                    Image(systemName: symbol(item.icon)).frame(width: 22)
                                    Text(item.text).lineLimit(1)
                                    Spacer()
                                    Text(item.date, style: .time)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .navigationTitle(T("nav_transfer"))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func symbol(_ name: String) -> String {
        switch name {
        case "upload": return "arrow.down.circle"
        case "download": return "arrow.up.circle"
        case "trash": return "trash"
        case "play": return "play.circle"
        default: return "stop.circle"
        }
    }

    private func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
