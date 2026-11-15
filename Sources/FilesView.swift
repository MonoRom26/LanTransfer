import SwiftUI

enum FilesSheet: Identifiable {
    case share(URL)
    case picker
    case newItem
    case rename(FileEntry)
    case player([URL], Int)
    case image(URL)
    case text(FileEntry)

    var id: String {
        switch self {
        case .share(let u): return "s" + u.path
        case .picker: return "p"
        case .newItem: return "n"
        case .rename(let e): return "r" + e.id
        case .player(let l, let i): return "pl\(i)" + (l.first?.path ?? "")
        case .image(let u): return "i" + u.path
        case .text(let e): return "t" + e.id
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
    @StateObject private var model = FilesModel()
    @State private var sheet: FilesSheet?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.footnote)
                        .foregroundColor(model.messageIsError ? .red : .green)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                }
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(T("working")).font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(6)
                }
                if !model.extensions.isEmpty { extensionChips }
                content
                if model.selecting { selectionBar }
            }
            .navigationTitle(model.atRoot ? T("tab_files") : model.dir.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if model.atRoot {
                        Button(action: { model.reload() }) { Image(systemName: "arrow.clockwise") }
                    } else {
                        Button(action: { model.goUp() }) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                Text(T("back"))
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { sheet = .picker }) {
                            Label { Text(T("add_files")) } icon: { Image(systemName: "square.and.arrow.down") }
                        }
                        Button(action: { sheet = .newItem }) {
                            Label { Text(T("new_item")) } icon: { Image(systemName: "folder.badge.plus") }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button(action: { model.selecting.toggle(); model.selection = [] }) {
                        Text(model.selecting ? T("done") : T("select"))
                    }
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .share(let u):
                    ActivityView(items: [u])
                case .picker:
                    DocumentPicker(onPick: { urls in sheet = nil; model.importFiles(urls) },
                                   onCancel: { sheet = nil })
                case .newItem:
                    NewItemSheet(model: model, onClose: { sheet = nil })
                case .rename(let e):
                    RenameSheet(model: model, entry: e, onClose: { sheet = nil })
                case .player(let list, let i):
                    MediaPlayerView(items: list, start: i, onClose: { sheet = nil })
                case .image(let u):
                    ImageViewer(url: u, model: model, onClose: { sheet = nil })
                case .text(let e):
                    TextEditorSheet(entry: e, model: model, onClose: { sheet = nil })
                }
            }
            .onAppear { model.reload() }
            .onChange(of: server.filesVersion) { _ in model.reload() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: extension filter
    private var extensionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(T("ext_all"), selected: model.filter.isEmpty) { model.filter = "" }
                ForEach(model.extensions, id: \.self) { e in
                    chip("." + e, selected: model.filter == e) { model.filter = e }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.secondarySystemBackground))
                .foregroundColor(selected ? .white : .primary)
                .cornerRadius(14)
        }
    }

    // MARK: list
    @ViewBuilder
    private var content: some View {
        if model.visible.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 44)).foregroundColor(.secondary)
                Text(T("empty_folder")).font(.headline)
                Text(T("no_files_hint"))
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
        } else {
            List {
                ForEach(model.visible) { e in
                    Button(action: { tap(e) }) {
                        FileRow(entry: e, selecting: model.selecting,
                                selected: model.selection.contains(e.id),
                                subtitle: subtitle(e))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu { menu(for: e) }
                }
                .onDelete { idx in
                    let list = idx.map { model.visible[$0] }
                    model.delete(list)
                }
            }
            .listStyle(PlainListStyle())
        }
    }

    private func subtitle(_ e: FileEntry) -> String {
        if e.isDir { return TF("folder_items", e.children) }
        return "\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)) • \(Self.dateFormatter.string(from: e.date))"
    }

    private func tap(_ e: FileEntry) {
        if model.selecting { model.toggle(e); return }
        switch e.kind {
        case .folder: model.open(e)
        case .video, .audio: play(e)
        case .image: sheet = .image(e.url)
        case .archive: model.unzip([e])
        case .text: sheet = .text(e)
        default: sheet = .share(e.url)
        }
    }

    private func play(_ e: FileEntry) {
        let list = model.visible.filter { $0.kind == .video || $0.kind == .audio }
        let idx = list.firstIndex(of: e) ?? 0
        sheet = .player(list.map { $0.url }, idx)
    }

    @ViewBuilder
    private func menu(for e: FileEntry) -> some View {
        if e.kind == .video || e.kind == .audio {
            Button(action: { play(e) }) {
                Label { Text(T("play")) } icon: { Image(systemName: "play") }
            }
        }
        if e.kind == .text || e.kind == .other {
            Button(action: { sheet = .text(e) }) {
                Label { Text(T("edit_text")) } icon: { Image(systemName: "doc.text") }
            }
        }
        if !e.isDir {
            Button(action: { sheet = .share(e.url) }) {
                Label { Text(T("share")) } icon: { Image(systemName: "square.and.arrow.up") }
            }
        }
        if e.kind == .image || e.kind == .video {
            Button(action: { model.saveToPhotos([e]) }) {
                Label { Text(T("save_photos")) } icon: { Image(systemName: "photo.on.rectangle") }
            }
        }
        if e.kind == .archive {
            Button(action: { model.unzip([e]) }) {
                Label { Text(T("unzip")) } icon: { Image(systemName: "folder.badge.plus") }
            }
        }
        Button(action: { model.compress([e]) }) {
            Label { Text(T("compress")) } icon: { Image(systemName: "doc.zipper") }
        }
        Button(action: { sheet = .rename(e) }) {
            Label { Text(T("rename")) } icon: { Image(systemName: "pencil") }
        }
        Button(action: { model.delete([e]) }) {
            Label { Text(T("delete")) } icon: { Image(systemName: "trash") }
        }
    }

    // MARK: selection bar
    private var selectionBar: some View {
        let chosen = model.selectedEntries
        return VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(TF("sel_count", chosen.count))
                        .font(.footnote).foregroundColor(.secondary)
                        .padding(.leading, 12)
                    barButton(model.filter.isEmpty ? T("select_all") : TF("select_ext", model.filter),
                              "checkmark.circle", disabled: false) { model.selectAllVisible() }
                    barButton(T("compress"), "doc.zipper", disabled: chosen.isEmpty) { model.compress(chosen) }
                    if chosen.contains(where: { $0.kind == .archive }) {
                        barButton(T("unzip"), "folder.badge.plus", disabled: false) { model.unzip(chosen) }
                    }
                    if chosen.contains(where: { $0.kind == .image || $0.kind == .video }) {
                        barButton(T("save_photos"), "photo.on.rectangle", disabled: false) { model.saveToPhotos(chosen) }
                    }
                    barButton(T("delete"), "trash", disabled: chosen.isEmpty) { model.delete(chosen) }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(.systemBackground))
    }

    private func barButton(_ title: String, _ icon: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(minWidth: 76, minHeight: 46)
            .padding(.horizontal, 4)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .opacity(disabled ? 0.35 : 1)
        }
        .disabled(disabled)
    }
}

struct FileRow: View {
    let entry: FileEntry
    let selecting: Bool
    let selected: Bool
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .blue : .secondary)
            }
            Image(systemName: icon).font(.title3).foregroundColor(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if entry.isDir {
                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
            } else if !entry.ext.isEmpty {
                Text(entry.ext.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(4)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .archive: return "doc.zipper"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .folder: return .yellow
        case .video: return .purple
        case .audio: return .pink
        case .image: return .green
        case .archive: return .orange
        default: return .blue
        }
    }
}

// MARK: - sheets
struct NewItemSheet: View {
    @ObservedObject var model: FilesModel
    var onClose: () -> Void
    @State private var isFolder = true
    @State private var name = ""
    @State private var content = ""
    @State private var error = ""

    var body: some View {
        NavigationView {
            Form {
                Picker("", selection: $isFolder) {
                    Text(T("new_folder")).tag(true)
                    Text(T("new_text_file")).tag(false)
                }
                .pickerStyle(SegmentedPickerStyle())

                Section(header: Text(T("name"))) {
                    TextField(T("name"), text: $name)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                if !isFolder {
                    Section(header: Text(T("content"))) {
                        TextEditor(text: $content).frame(minHeight: 140)
                    }
                }
                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundColor(.red)
                }
            }
            .navigationTitle(T("new_item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onClose) { Text(T("cancel")) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: create) { Text(T("create")).bold() }
                }
            }
        }
    }

    private func create() {
        let result = isFolder ? model.createFolder(name) : model.createTextFile(name, content: content)
        if let e = result { error = e } else { onClose() }
    }
}

struct RenameSheet: View {
    @ObservedObject var model: FilesModel
    let entry: FileEntry
    var onClose: () -> Void
    @State private var name = ""
    @State private var error = ""

    var body: some View {
        NavigationView {
            Form {
                TextField(T("name"), text: $name)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundColor(.red)
                }
            }
            .navigationTitle(T("rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onClose) { Text(T("cancel")) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: save) { Text(T("done")).bold() }
                }
            }
            .onAppear { name = entry.name }
        }
    }

    private func save() {
        if let e = model.rename(entry, to: name) { error = e } else { onClose() }
    }
}

struct ImageViewer: View {
    let url: URL
    @ObservedObject var model: FilesModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary)
                }
            }
            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Spacer()
                Text(T("cant_play")).foregroundColor(.secondary)
                Spacer()
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.footnote)
                    .foregroundColor(model.messageIsError ? .red : .green)
            }
            HStack(spacing: 12) {
                Button(action: { model.saveToPhotos([FileEntry(url: url, isDir: false, size: 0, date: Date(), children: 0)]) }) {
                    Label { Text(T("save_photos")) } icon: { Image(systemName: "photo.on.rectangle") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(color: .blue))
            }
        }
        .padding()
    }
}

// MARK: - text viewer / editor
struct TextEditorSheet: View {
    let entry: FileEntry
    @ObservedObject var model: FilesModel
    var onClose: () -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var encoding = String.Encoding.utf8
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        NavigationView {
            Group {
                if !error.isEmpty {
                    VStack {
                        Spacer()
                        Text(error).foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                        Spacer()
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)
                }
            }
            .navigationTitle(entry.name + (text != original ? " •" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onClose) { Text(T("cancel")) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: save) { Text(T("save")).bold() }
                        .disabled(!error.isEmpty || text == original)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(action: hideKeyboard) { Text(T("done")) }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if entry.size > 2_000_000 { error = T("file_too_big"); return }
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: entry.url, usedEncoding: &enc) {
            text = s
            original = s
            encoding = enc
        } else if let s = try? String(contentsOf: entry.url, encoding: .isoLatin1) {
            text = s
            original = s
            encoding = .isoLatin1
        } else {
            error = T("cant_read_text")
        }
    }

    private func save() {
        do {
            do {
                try text.write(to: entry.url, atomically: true, encoding: encoding)
            } catch {
                try text.write(to: entry.url, atomically: true, encoding: .utf8)
                encoding = .utf8
            }
            original = text
            model.flash(T("saved"))
            model.reload()
        } catch {
            model.flash(TF("op_failed", error.localizedDescription), error: true)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
