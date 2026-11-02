import SwiftUI
import CoreImage.CIFilterBuiltins

struct TransferView: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if server.isRunning {
                        if let qr = qrImage(for: server.urlString) {
                            Image(uiImage: qr).interpolation(.none)
                                .resizable().frame(width: 190, height: 190)
                        }
                        Text("Open on your PC browser")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(server.urlString)
                            .font(.title3.monospaced()).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = server.urlString
                        } label: { Label("Copy address", systemImage: "doc.on.doc") }
                            .buttonStyle(.bordered)
                    } else {
                        Image(systemName: "wifi").font(.system(size: 60))
                            .foregroundStyle(.secondary).padding(.top, 40)
                        Text("Server is stopped")
                    }

                    if !server.errorText.isEmpty {
                        Text(server.errorText).font(.footnote).foregroundStyle(.red)
                    }

                    Button(server.isRunning ? "Stop Server" : "Start Server") {
                        server.isRunning ? server.stop() : server.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(server.isRunning ? .red : .blue)
                    .controlSize(.large)

                    if !server.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Activity").font(.headline)
                            ForEach(server.activity) { item in
                                HStack {
                                    Image(systemName: symbol(item.icon)).frame(width: 22)
                                    Text(item.text).lineLimit(1)
                                    Spacer()
                                    Text(item.date, style: .time)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("LAN Transfer")
        }
    }

    private func symbol(_ name: String) -> String {
        switch name {
        case "upload": return "arrow.down.circle"      // received on phone
        case "download": return "arrow.up.circle"      // sent to PC
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
