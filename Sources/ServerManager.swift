import Foundation
import UIKit
import GCDWebServers

struct ActivityItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let date = Date()
}

final class ServerManager: NSObject, ObservableObject, GCDWebUploaderDelegate {
    @Published var isRunning = false
    @Published var urlString = ""
    @Published var errorText = ""
    @Published var activity: [ActivityItem] = []
    @Published var filesVersion = 0   // bump to make the Files tab reload

    private var uploader: GCDWebUploader?

    static var documentsPath: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }

    func start() {
        let d = UserDefaults.standard
        let port = d.object(forKey: "port") as? Int ?? 8080
        let usePassword = d.bool(forKey: "usePassword")
        let password = d.string(forKey: "password") ?? ""
        let keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        let bonjour = d.bool(forKey: "bonjour")

        let server = GCDWebUploader(uploadDirectory: Self.documentsPath)
        server.allowHiddenItems = false
        server.delegate = self

        var options: [String: Any] = [GCDWebServerOption_Port: port]
        if bonjour { options[GCDWebServerOption_BonjourName] = "LanTransfer" }
        if usePassword && !password.isEmpty {
            options[GCDWebServerOption_AuthenticationMethod] = GCDWebServerAuthenticationMethod_Basic
            options[GCDWebServerOption_AuthenticationAccounts] = ["admin": password]
        }

        do {
            try server.start(options: options)
        } catch {
            errorText = "Could not start: \(error.localizedDescription)"
            return
        }

        uploader = server
        errorText = ""
        if let ip = Self.wifiIPAddress() {
            urlString = "http://\(ip):\(port)"
        } else {
            urlString = server.serverURL?.absoluteString ?? ""
            errorText = "Not connected to Wi-Fi?"
        }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        log("play", "Server started")
    }

    func stop() {
        uploader?.stop()
        uploader = nil
        isRunning = false
        urlString = ""
        UIApplication.shared.isIdleTimerDisabled = false
        log("player-stop", "Server stopped")
    }

    private func log(_ icon: String, _ text: String) {
        DispatchQueue.main.async {
            self.activity.insert(ActivityItem(icon: icon, text: text), at: 0)
            if self.activity.count > 50 { self.activity.removeLast() }
        }
    }

    // MARK: GCDWebUploaderDelegate
    func webUploader(_ uploader: GCDWebUploader, didUploadFileAtPath path: String) {
        log("upload", "Received \((path as NSString).lastPathComponent)")
        DispatchQueue.main.async { self.filesVersion += 1 }
    }
    func webUploader(_ uploader: GCDWebUploader, didDownloadFileAtPath path: String) {
        log("download", "Sent \((path as NSString).lastPathComponent)")
    }
    func webUploader(_ uploader: GCDWebUploader, didDeleteItemAtPath path: String) {
        log("trash", "Deleted \((path as NSString).lastPathComponent)")
        DispatchQueue.main.async { self.filesVersion += 1 }
    }

    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
        }
        return address
    }
}
