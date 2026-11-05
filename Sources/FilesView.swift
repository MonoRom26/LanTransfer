import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    var name: String { url.lastPathComponent }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
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
    @State private var showImporter = false
    @State private var shareItem: ShareItem?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationView {
            Group {
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 44)).foregroundColor(.secondary)
                        Text("No files yet").font(.headline)
                        Text("Upload from your PC or tap + to add files.")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
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
                                Button {
                                    shareItem = ShareItem(url: f.url)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let dest = URL(fileURLWithPath: ServerManager.documentsPath)
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
                reload()
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
            .onAppear { reload() }
            .onChange(of: server.filesVersion) { _ in reload() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
