import Foundation
import UIKit

struct ActivityItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let date = Date()
}

final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var urlString = ""
    @Published var errorText = ""
    @Published var activity: [ActivityItem] = []
    @Published var filesVersion = 0   // bump to make the Files tab reload

    private var server: MiniServer?

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

        let s = MiniServer(root: URL(fileURLWithPath: Self.documentsPath),
                           password: usePassword ? password : "")
        s.onEvent = { [weak self] kind, name in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch kind {
                case "upload":
                    self.log("upload", "Received \(name)"); self.filesVersion += 1
                case "download":
                    self.log("download", "Sent \(name)")
                case "delete":
                    self.log("trash", "Deleted \(name)"); self.filesVersion += 1
                default: break
                }
            }
        }
        s.onFailure = { [weak self] msg in
            DispatchQueue.main.async {
                self?.stop()
                self?.errorText = "Server error: \(msg)"
            }
        }

        do {
            try s.start(port: UInt16(clamping: port), bonjour: bonjour)
        } catch {
            errorText = "Could not start: \(error.localizedDescription)"
            return
        }

        server = s
        errorText = ""
        if let ip = Self.wifiIPAddress() {
            urlString = "http://\(ip):\(port)"
        } else {
            urlString = "http://localhost:\(port)"
            errorText = "Not connected to Wi-Fi?"
        }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        log("play", "Server started")
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        urlString = ""
        UIApplication.shared.isIdleTimerDisabled = false
        log("stop", "Server stopped")
    }

    private func log(_ icon: String, _ text: String) {
        activity.insert(ActivityItem(icon: icon, text: text), at: 0)
        if activity.count > 50 { activity.removeLast() }
    }

    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            // ifa_addr can be NULL on some interfaces (e.g. iPhone 12 with 5G) -> skip them
            guard let addr = ifa.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
