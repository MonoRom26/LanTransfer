import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    var name: String { url.lastPathComponent }
}

enum FilesSheet: Identifiable {
    case share(URL)
    case picker
    var id: String {
        switch self {
        case .share(let u): return "share-" + u.path
        case .picker: return "picker"
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct FilesView: View {
    @ObservedObject var server: ServerManager
    @State private var files: [FileItem] = []
    @State private var sheet: FilesSheet?
    @State private var message = ""
    @State private var messageIsError = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(messageIsError ? .red : .green)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                }
                Group {
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 44)).foregroundColor(.secondary)
                        Text(T("no_files")).font(.headline)
                        Text(T("no_files_hint"))
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(files) { f in
                            HStack {
                                Image(systemName: "doc").foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text(f.name).lineLimit(1)
                                    Text("\(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)) • \(Self.dateFormatter.string(from: f.date))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: { sheet = .share(f.url) }) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
                }
            }
            .navigationTitle(T("tab_files"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { reload() }) { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { sheet = .picker }) { Image(systemName: "plus") }
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .share(let url):
                    ActivityView(items: [url])
                case .picker:
                    DocumentPicker(
                        onPick: { urls in importFiles(urls); sheet = nil },
                        onCancel: { sheet = nil })
                }
            }
            .onAppear { reload() }
            .onChange(of: server.filesVersion) { _ in reload() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func importFiles(_ urls: [URL]) {
        var added = 0
        var lastError = ""
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = uniqueDestination(url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                added += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        if !lastError.isEmpty {
            message = TF("add_failed", lastError)
            messageIsError = true
        } else {
            message = TF("added_files", added)
            messageIsError = false
        }
        reload()
    }

    private func uniqueDestination(_ rawName: String) -> URL {
        let name = (rawName as NSString).lastPathComponent
        let dir = URL(fileURLWithPath: ServerManager.documentsPath)
        var dest = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            dest = dir.appendingPathComponent(n)
            i += 1
        }
        return dest
    }

    private func reload() {
        let dir = URL(fileURLWithPath: ServerManager.documentsPath)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        files = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(url: u, size: Int64(v?.fileSize ?? 0),
                            date: v?.contentModificationDate ?? Date())
        }.sorted { $0.date > $1.date }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: files[i].url) }
        reload()
    }
}
