import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    var name: String { url.lastPathComponent }
}

struct FilesView: View {
    @ObservedObject var server: ServerManager
    @State private var files: [FileItem] = []
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("No files yet").font(.headline)
                        Text("Upload from your PC or tap + to add files.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(files) { f in
                            HStack {
                                Image(systemName: "doc").foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(f.name).lineLimit(1)
                                    Text("\(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)) • \(f.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Files")
            .toolbar {
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
            .refreshable { reload() }
            .onAppear { reload() }
            .onChange(of: server.filesVersion) { _ in reload() }
        }
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
