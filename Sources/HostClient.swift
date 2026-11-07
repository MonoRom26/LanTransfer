import Foundation

struct RemoteFile: Identifiable {
    let name: String
    let size: Int64
    var id: String { name }
}

enum TransferState { case running, done, failed }

struct TransferItem: Identifiable {
    let id = UUID()
    let name: String
    let isUpload: Bool
    var progress: Double = 0
    var state: TransferState = .running
}

enum ClientError: Error { case unauthorized, failed }

/// Connects to another iPhone's server: list, download, upload.
final class HostClient: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hostName = ""
    @Published var hostAddress = ""
    @Published var files: [RemoteFile] = []
    @Published var transfers: [TransferItem] = []
    @Published var errorKey: String?

    var onSaved: (() -> Void)?

    private var base: URL?
    private var auth: String?
    private var taskMap: [Int: UUID] = [:]
    private var savedTasks = Set<Int>()
    private var tempDirs: [Int: URL] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()

    // MARK: connect / disconnect
    func connect(address: String, name: String, password: String) {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        let lower = a.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { a = "http://" + a }
        guard var comps = URLComponents(string: a), comps.host != nil else {
            errorKey = "err_connect"; return
        }
        if comps.port == nil { comps.port = 8080 }
        comps.path = ""
        comps.query = nil
        guard let b = comps.url else { errorKey = "err_connect"; return }

        base = b
        auth = password.isEmpty ? nil
            : "Basic " + Data("admin:\(password)".utf8).base64EncodedString()
        isConnecting = true
        errorKey = nil

        fetchList { [weak self] result in
            guard let self = self else { return }
            self.isConnecting = false
            switch result {
            case .success(let list):
                self.files = list
                self.hostName = name.isEmpty ? (b.host ?? "") : name
                self.hostAddress = "\(b.host ?? ""):\(b.port ?? 8080)"
                self.isConnected = true
            case .failure(let e):
                self.errorKey = (e == .unauthorized) ? "err_password" : "err_connect"
                self.base = nil
            }
        }
    }

    func disconnect() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        isConnected = false
        base = nil
        auth = nil
        files = []
        transfers = []
        errorKey = nil
    }

    func refresh() {
        fetchList { [weak self] result in
            if case .success(let list) = result { self?.files = list }
        }
    }

    // MARK: requests
    private func makeRequest(_ path: String, name: String? = nil,
                             method: String = "GET", timeout: TimeInterval = 10) -> URLRequest? {
        guard let base = base, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = path
        if let n = name { c.queryItems = [URLQueryItem(name: "name", value: n)] }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let a = auth { r.setValue(a, forHTTPHeaderField: "Authorization") }
        return r
    }

    private func fetchList(_ done: @escaping (Result<[RemoteFile], ClientError>) -> Void) {
        guard let req = makeRequest("/api/list") else { done(.failure(.failed)); return }
        session.dataTask(with: req) { data, resp, err in
            if let h = resp as? HTTPURLResponse {
                if h.statusCode == 401 { done(.failure(.unauthorized)); return }
                if h.statusCode != 200 { done(.failure(.failed)); return }
            }
            guard err == nil, let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                done(.failure(.failed)); return
            }
            let list: [RemoteFile] = arr.compactMap { d in
                guard let n = d["name"] as? String else { return nil }
                let s = (d["size"] as? NSNumber)?.int64Value ?? 0
                return RemoteFile(name: n, size: s)
            }
            done(.success(list))
        }.resume()
    }

    // MARK: download
    func download(_ f: RemoteFile) {
        guard let req = makeRequest("/download", name: f.name, timeout: 30) else { return }
        let task = session.downloadTask(with: req)
        let item = TransferItem(name: f.name, isUpload: false)
        transfers.insert(item, at: 0)
        taskMap[task.taskIdentifier] = item.id
        task.resume()
    }

    // MARK: upload
    func upload(urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let tmp = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch { continue }

            guard var req = makeRequest("/upload", name: url.lastPathComponent,
                                        method: "POST", timeout: 60) else {
                try? FileManager.default.removeItem(at: dir); continue
            }
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: req, fromFile: tmp)
            let item = TransferItem(name: url.lastPathComponent, isUpload: true)
            transfers.insert(item, at: 0)
            taskMap[task.taskIdentifier] = item.id
            tempDirs[task.taskIdentifier] = dir
            task.resume()
        }
    }

    // MARK: helpers
    private func setProgress(_ taskId: Int, _ value: Double) {
        guard let id = taskMap[taskId], let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].progress = value
    }

    private func uniqueURL(_ rawName: String) -> URL {
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

    // MARK: URLSession delegates
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        setProgress(downloadTask.taskIdentifier,
                    Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let id = taskMap[downloadTask.taskIdentifier],
              let item = transfers.first(where: { $0.id == id }) else { return }
        let dest = uniqueURL(item.name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            savedTasks.insert(downloadTask.taskIdentifier)
        } catch {}
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        setProgress(task.taskIdentifier, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let isDownload = task is URLSessionDownloadTask
        var ok = (error == nil && status == 200)
        if isDownload { ok = ok && savedTasks.contains(tid) }
        savedTasks.remove(tid)
        if let dir = tempDirs.removeValue(forKey: tid) {
            try? FileManager.default.removeItem(at: dir)
        }
        if let id = taskMap.removeValue(forKey: tid),
           let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = ok ? .done : .failed
            if ok { transfers[i].progress = 1 }
        }
        if ok && isDownload { onSaved?() }
    }
}
