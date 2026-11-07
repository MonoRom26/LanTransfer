import Foundation
import Network

/// Tiny dependency-free HTTP server (Network framework) for LAN file transfer.
final class MiniServer {
    fileprivate let queue = DispatchQueue(label: "lantransfer.server")
    fileprivate var sessions: [ObjectIdentifier: Session] = [:]
    private var listener: NWListener?

    let root: URL
    let password: String
    var lang = "en"
    var onEvent: ((_ kind: String, _ name: String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(root: URL, password: String) {
        self.root = root
        self.password = password
    }

    func start(port: UInt16, serviceName: String?) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MiniServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let l = try NWListener(using: .tcp, on: p)
        if let n = serviceName {
            l.service = NWListener.Service(name: n, type: "_lantransfer._tcp")
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            let s = Session(conn: conn, server: self)
            self.sessions[ObjectIdentifier(s)] = s
            s.start()
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.onFailure?(e.localizedDescription) }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            for s in Array(self.sessions.values) { s.close() }
            self.sessions.removeAll()
        }
    }

    // MARK: helpers
    fileprivate func safeName(_ n: String?) -> String? {
        guard let raw = n?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let name = (raw as NSString).lastPathComponent
        if name.isEmpty || name.hasPrefix(".") { return nil }
        return name
    }

    fileprivate func listJSON() -> Data {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var items: [[String: Any]] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { continue }
            items.append(["name": u.lastPathComponent,
                          "size": v?.fileSize ?? 0,
                          "date": (v?.contentModificationDate ?? Date()).timeIntervalSince1970])
        }
        items.sort { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
    }
}

// MARK: - One HTTP connection
fileprivate final class Session {
    let conn: NWConnection
    let server: MiniServer
    var buffer = Data()
    var headerParsed = false
    var finished = false
    var closed = false
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var contentLength = 0
    var received = 0
    var handle: FileHandle?
    var tempURL: URL?
    var destURL: URL?
    var uploadName = ""

    init(conn: NWConnection, server: MiniServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
    }

    func close() {
        if closed { return }
        closed = true
        if let h = handle { try? h.close(); handle = nil }
        if let t = tempURL { try? FileManager.default.removeItem(at: t); tempURL = nil }
        conn.cancel()
        server.queue.async { [weak self] in
            guard let self = self else { return }
            self.server.sessions.removeValue(forKey: ObjectIdentifier(self))
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty { self.consume(d) }
            if error != nil { self.close(); return }
            if self.finished || self.closed { return }
            if isComplete { self.close(); return }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        if finished { return }
        if headerParsed {
            writeBody(data)
            return
        }
        buffer.append(data)
        guard let r = buffer.range(of: Data([13, 10, 13, 10])) else {
            if buffer.count > 65_536 { respond(431, "Request Header Fields Too Large", text: "Too large") }
            return
        }
        let head = buffer.subdata(in: 0..<r.lowerBound)
        let rest = buffer.subdata(in: r.upperBound..<buffer.count)
        buffer = Data()
        guard parseHead(head) else { respond(400, "Bad Request", text: "Bad request"); return }
        headerParsed = true
        guard authorized() else {
            respond(401, "Unauthorized", text: "Password required",
                    extra: ["WWW-Authenticate": "Basic realm=\"LAN Transfer\""])
            return
        }
        route(rest)
    }

    private func parseHead(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return false }
        method = String(parts[0]).uppercased()
        guard let comps = URLComponents(string: "http://x" + String(parts[1])) else { return false }
        path = comps.path
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<idx].lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        contentLength = Int(headers["content-length"] ?? "0") ?? 0
        return true
    }

    private func authorized() -> Bool {
        if server.password.isEmpty { return true }
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("basic "),
              let d = Data(base64Encoded: String(auth.dropFirst(6))),
              let s = String(data: d, encoding: .utf8) else { return false }
        return s == "admin:\(server.password)"
    }

    // MARK: routing
    private func route(_ rest: Data) {
        switch (method, path) {
        case ("GET", "/"):
            let html = indexHTML.replacingOccurrences(of: "__LANG__", with: server.lang)
            respond(200, "OK", body: Data(html.utf8), type: "text/html; charset=utf-8")
        case ("GET", "/api/list"):
            respond(200, "OK", body: server.listJSON(), type: "application/json")
        case ("GET", "/download"):
            download()
        case ("POST", "/upload"):
            beginUpload(rest)
        case ("POST", "/delete"):
            deleteFile()
        default:
            respond(404, "Not Found", text: "Not found")
        }
    }

    private func download() {
        guard let name = server.safeName(query["name"]) else { respond(400, "Bad Request", text: "Bad name"); return }
        let url = server.root.appendingPathComponent(name)
        guard let fh = try? FileHandle(forReadingFrom: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            respond(404, "Not Found", text: "No such file"); return
        }
        finished = true
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size.int64Value)\r\nContent-Disposition: attachment; filename*=UTF-8''\(enc)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { try? fh.close(); self.close(); return }
            self.pump(fh, name: name)
        })
    }

    private func pump(_ fh: FileHandle, name: String) {
        let chunk = (try? fh.read(upToCount: 262_144)) ?? nil
        guard let data = chunk, !data.isEmpty else {
            try? fh.close()
            server.onEvent?("download", name)
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { try? fh.close(); self.close(); return }
            self.pump(fh, name: name)
        })
    }

    private func deleteFile() {
        guard let name = server.safeName(query["name"]) else { respond(400, "Bad Request", text: "Bad name"); return }
        let url = server.root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        server.onEvent?("delete", name)
        respond(200, "OK", body: Data("{\"ok\":true}".utf8), type: "application/json")
    }

    private func beginUpload(_ rest: Data) {
        guard let name = server.safeName(query["name"]) else { respond(400, "Bad Request", text: "Bad name"); return }
        guard headers["content-length"] != nil else { respond(411, "Length Required", text: "Length required"); return }
        uploadName = name
        destURL = server.root.appendingPathComponent(name)
        let temp = server.root.appendingPathComponent(".upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let h = try? FileHandle(forWritingTo: temp) else {
            respond(500, "Server Error", text: "Cannot create file"); return
        }
        tempURL = temp
        handle = h
        if contentLength == 0 { finishUpload(); return }
        if !rest.isEmpty { writeBody(rest) }
    }

    private func writeBody(_ data: Data) {
        guard let h = handle else { return }
        let remaining = contentLength - received
        let slice = data.count > remaining ? data.prefix(remaining) : data
        do { try h.write(contentsOf: slice) } catch {
            respond(500, "Server Error", text: "Write failed"); return
        }
        received += slice.count
        if received >= contentLength { finishUpload() }
    }

    private func finishUpload() {
        guard let temp = tempURL, let dest = destURL else { return }
        if let h = handle { try? h.close(); handle = nil }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
            tempURL = nil
            server.onEvent?("upload", uploadName)
            respond(200, "OK", body: Data("{\"ok\":true}".utf8), type: "application/json")
        } catch {
            respond(500, "Server Error", text: "Move failed")
        }
    }

    // MARK: responses
    private func respond(_ status: Int, _ reason: String, text: String, extra: [String: String] = [:]) {
        respond(status, reason, body: Data(text.utf8), type: "text/plain; charset=utf-8", extra: extra)
    }

    private func respond(_ status: Int, _ reason: String, body: Data,
                         type: String, extra: [String: String] = [:]) {
        if finished { return }
        finished = true
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}

// MARK: - Web page shown on the PC
private let indexHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LAN Transfer</title>
<style>
:root{color-scheme:light dark;font-family:-apple-system,Segoe UI,Roboto,"Noto Sans Khmer","Khmer UI","Malgun Gothic","Microsoft YaHei",sans-serif}
body{max-width:760px;margin:0 auto;padding:20px}
.top{display:flex;justify-content:space-between;align-items:center}
h1{font-size:22px}
select{font-size:14px;padding:4px 8px;border-radius:6px}
#drop{border:2px dashed #888;border-radius:12px;padding:32px;text-align:center;margin:16px 0}
#drop.over{background:rgba(24,95,165,.15);border-color:#185FA5}
.btn{background:#185FA5;color:#fff;border:0;border-radius:8px;padding:6px 12px;cursor:pointer;font-size:14px;text-decoration:none;display:inline-block}
.btn.red{background:#A32D2D}
.row{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid rgba(128,128,128,.3)}
.name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meta{font-size:12px;opacity:.65}
progress{width:140px}
</style></head><body>
<div class="top"><h1>LAN Transfer</h1>
<select id="lg"><option value="en">English</option><option value="ko">한국어</option><option value="km">ខ្មែរ</option><option value="zh">中文</option></select></div>
<div id="drop"><span id="t_drop"></span> <label class="btn"><span id="t_choose"></span><input id="pick" type="file" multiple hidden></label></div>
<div id="uploads"></div>
<h2 style="font-size:16px" id="t_head"></h2>
<div id="list"></div>
<script>
const S={
 en:{drop:'Drop files here, or',choose:'Choose files',head:'Files on iPhone',none:'No files yet.',dl:'Download',del:'Delete',conf:'Delete this file?',up:'Uploading',done:'Done',fail:'Failed'},
 ko:{drop:'파일을 여기에 놓거나',choose:'파일 선택',head:'iPhone의 파일',none:'파일이 없습니다.',dl:'다운로드',del:'삭제',conf:'이 파일을 삭제할까요?',up:'업로드 중',done:'완료',fail:'실패'},
 km:{drop:'ទម្លាក់ឯកសារនៅទីនេះ ឬ',choose:'ជ្រើសរើសឯកសារ',head:'ឯកសារនៅលើ iPhone',none:'មិនទាន់មានឯកសារទេ។',dl:'ទាញយក',del:'លុប',conf:'លុបឯកសារនេះឬ?',up:'កំពុងផ្ទុកឡើង',done:'រួចរាល់',fail:'បរាជ័យ'},
 zh:{drop:'将文件拖到此处，或',choose:'选择文件',head:'iPhone 上的文件',none:'暂无文件。',dl:'下载',del:'删除',conf:'删除此文件？',up:'正在上传',done:'完成',fail:'失败'}
};
let L=S['__LANG__']?'__LANG__':'en';
const t=k=>S[L][k];
const $=id=>document.getElementById(id);
function fmt(n){if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB'}
async function load(){
  const r=await fetch('/api/list');const items=await r.json();const box=$('list');box.textContent='';
  if(!items.length){box.textContent=t('none');return}
  for(const it of items){
    const row=document.createElement('div');row.className='row';
    const n=document.createElement('div');n.className='name';n.textContent=it.name;
    const m=document.createElement('div');m.className='meta';m.textContent=fmt(it.size);
    const d=document.createElement('a');d.className='btn';d.textContent=t('dl');
    d.href='/download?name='+encodeURIComponent(it.name);
    const x=document.createElement('button');x.className='btn red';x.textContent=t('del');
    x.onclick=async()=>{if(confirm(t('conf')+'\n'+it.name)){await fetch('/delete?name='+encodeURIComponent(it.name),{method:'POST'});load()}};
    row.append(n,m,d,x);box.append(row);
  }
}
function upload(file){
  return new Promise(res=>{
    const row=document.createElement('div');row.className='row';
    const n=document.createElement('div');n.className='name';n.textContent=file.name;
    const p=document.createElement('progress');p.max=1;p.value=0;
    const s=document.createElement('div');s.className='meta';s.textContent=t('up');
    row.append(n,p,s);$('uploads').append(row);
    const x=new XMLHttpRequest();
    x.open('POST','/upload?name='+encodeURIComponent(file.name));
    x.upload.onprogress=e=>{if(e.lengthComputable)p.value=e.loaded/e.total};
    x.onload=()=>{s.textContent=x.status==200?t('done'):t('fail');if(x.status==200)setTimeout(()=>row.remove(),2000);res()};
    x.onerror=()=>{s.textContent=t('fail');res()};
    x.send(file);
  });
}
async function handle(files){for(const f of files){await upload(f)}load()}
function applyLang(){$('t_drop').textContent=t('drop');$('t_choose').textContent=t('choose');$('t_head').textContent=t('head');$('lg').value=L;load()}
$('lg').onchange=e=>{L=e.target.value;applyLang()};
$('pick').onchange=e=>handle(e.target.files);
const dz=$('drop');
dz.ondragover=e=>{e.preventDefault();dz.classList.add('over')};
dz.ondragleave=()=>dz.classList.remove('over');
dz.ondrop=e=>{e.preventDefault();dz.classList.remove('over');handle(e.dataTransfer.files)};
applyLang();
</script></body></html>
"""#
