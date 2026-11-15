import Foundation
import Photos
import ZIPFoundation

enum FileKind { case folder, video, audio, image, archive, text, other }

struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let date: Date
    let children: Int

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var kind: FileKind {
        if isDir { return .folder }
        switch ext {
        case "mp4", "mov", "m4v": return .video
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "caf": return .audio
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "bmp": return .image
        case "zip": return .archive
        case "txt", "md", "json", "csv", "log", "xml", "html", "rtf": return .text
        default: return .other
        }
    }
}

/// File browser state for the Files tab: folders, selection, zip, create, rename, save to Photos.
final class FilesModel: ObservableObject {
    @Published var dir: URL
    @Published var entries: [FileEntry] = []
    @Published var selecting = false
    @Published var selection: Set<String> = []
    @Published var filter = ""
    @Published var message = ""
    @Published var messageIsError = false
    @Published var busy = false

    let root: URL

    init() {
        let r = URL(fileURLWithPath: ServerManager.documentsPath)
        root = r
        dir = r
    }

    // MARK: derived
    var atRoot: Bool { dir.standardizedFileURL.path == root.standardizedFileURL.path }

    var extensions: [String] {
        Array(Set(entries.filter { !$0.isDir && !$0.ext.isEmpty }.map { $0.ext })).sorted()
    }

    var visible: [FileEntry] {
        filter.isEmpty ? entries : entries.filter { $0.isDir || $0.ext == filter }
    }

    var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.id) } }

    // MARK: loading
    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var list: [FileEntry] = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            let count = isDir ? ((try? FileManager.default.contentsOfDirectory(atPath: u.path))?.count ?? 0) : 0
            return FileEntry(url: u, isDir: isDir, size: Int64(v?.fileSize ?? 0),
                             date: v?.contentModificationDate ?? Date(), children: count)
        }
        list.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        entries = list
        let ids = Set(list.map { $0.id })
        selection = selection.intersection(ids)
        if !filter.isEmpty && !list.contains(where: { $0.ext == filter }) { filter = "" }
    }

    func flash(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
        let current = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.message == current { self.message = "" }
        }
    }

    // MARK: navigation / selection
    func open(_ folder: FileEntry) {
        dir = folder.url
        selection = []
        filter = ""
        reload()
    }

    func goUp() {
        guard !atRoot else { return }
        dir = dir.deletingLastPathComponent()
        selection = []
        filter = ""
        reload()
    }

    func toggle(_ e: FileEntry) {
        if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) }
    }

    func selectAllVisible() {
        let list = visible.filter { filter.isEmpty || !$0.isDir }
        selection = Set(list.map { $0.id })
    }

    // MARK: helpers
    private func uniqueURL(_ name: String, in folder: URL) -> URL {
        var dest = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            dest = folder.appendingPathComponent(n)
            i += 1
        }
        return dest
    }

    private func validName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.contains("/") || n.contains(":") || n == "." || n == ".." { return nil }
        return n
    }

    // MARK: create / rename / delete / import
    func createFolder(_ name: String) -> String? {
        guard let n = validName(name) else { return T("invalid_name") }
        let u = dir.appendingPathComponent(n)
        if FileManager.default.fileExists(atPath: u.path) { return T("name_exists") }
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        } catch {
            return error.localizedDescription
        }
        reload()
        return nil
    }

    func createTextFile(_ name: String, content: String) -> String? {
        guard var n = validName(name) else { return T("invalid_name") }
        if (n as NSString).pathExtension.isEmpty { n += ".txt" }
        let u = dir.appendingPathComponent(n)
        if FileManager.default.fileExists(atPath: u.path) { return T("name_exists") }
        do {
            try content.write(to: u, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        reload()
        return nil
    }

    func rename(_ e: FileEntry, to name: String) -> String? {
        guard let n = validName(name) else { return T("invalid_name") }
        let u = e.url.deletingLastPathComponent().appendingPathComponent(n)
        if u.path == e.url.path { return nil }
        if FileManager.default.fileExists(atPath: u.path) { return T("name_exists") }
        do {
            try FileManager.default.moveItem(at: e.url, to: u)
        } catch {
            return error.localizedDescription
        }
        reload()
        return nil
    }

    func delete(_ list: [FileEntry]) {
        for e in list { try? FileManager.default.removeItem(at: e.url) }
        selection = []
        reload()
    }

    func importFiles(_ urls: [URL]) {
        var added = 0
        var lastError = ""
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = uniqueURL(url.lastPathComponent, in: dir)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                added += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        if lastError.isEmpty { flash(TF("added_files", added)) } else { flash(TF("add_failed", lastError), error: true) }
        reload()
    }

    // MARK: zip / unzip
    func compress(_ list: [FileEntry]) {
        guard !list.isEmpty, !busy else { return }
        busy = true
        message = ""
        let folder = dir
        let base = list.count == 1 ? (list[0].name as NSString).deletingPathExtension : "Archive"
        let dest = uniqueURL(base + ".zip", in: folder)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var err: String?
            do {
                if list.count == 1 {
                    try fm.zipItem(at: list[0].url, to: dest, shouldKeepParent: true, compressionMethod: .deflate)
                } else {
                    let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    for e in list { try fm.copyItem(at: e.url, to: staging.appendingPathComponent(e.name)) }
                    try fm.zipItem(at: staging, to: dest, shouldKeepParent: false, compressionMethod: .deflate)
                    try? fm.removeItem(at: staging)
                }
            } catch {
                err = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                self.selecting = false
                self.selection = []
                if let e = err { self.flash(TF("op_failed", e), error: true) }
                else { self.flash(TF("zip_created", dest.lastPathComponent)) }
                self.reload()
            }
        }
    }

    func unzip(_ list: [FileEntry]) {
        let zips = list.filter { $0.kind == .archive }
        guard !zips.isEmpty else { flash(T("zip_unsupported"), error: true); return }
        guard !busy else { return }
        busy = true
        message = ""
        let folder = dir
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var err: String?
            var lastName = ""
            for z in zips {
                let base = (z.name as NSString).deletingPathExtension
                let target = self.uniqueURL(base, in: folder)
                do {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try fm.unzipItem(at: z.url, to: target)
                    lastName = target.lastPathComponent
                } catch {
                    err = error.localizedDescription
                    try? fm.removeItem(at: target)
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.selecting = false
                self.selection = []
                if let e = err { self.flash(TF("op_failed", e), error: true) }
                else { self.flash(TF("unzipped", lastName)) }
                self.reload()
            }
        }
    }

    // MARK: save to Photos
    func saveToPhotos(_ list: [FileEntry]) {
        let media = list.filter { $0.kind == .image || $0.kind == .video }
        guard !media.isEmpty else { flash(T("not_media"), error: true); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.flash(T("photos_denied"), error: true) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for e in media {
                    if e.kind == .image {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: e.url)
                    } else {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: e.url)
                    }
                }
            }, completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        self.flash(T("saved_photos"))
                        self.selecting = false
                        self.selection = []
                    } else {
                        self.flash(TF("op_failed", err?.localizedDescription ?? ""), error: true)
                    }
                }
            })
        }
    }
}
