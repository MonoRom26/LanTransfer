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
        let discoverable = d.object(forKey: "discoverable") as? Bool ?? true

        let ip = Self.wifiIPAddress()
        var serviceName: String?
        if discoverable, let ip = ip {
            serviceName = Self.serviceName(ip: ip, port: port)
        }

        let s = MiniServer(root: URL(fileURLWithPath: Self.documentsPath),
                           password: usePassword ? password : "")
        s.lang = Lang.current.rawValue
        s.onEvent = { [weak self] kind, name in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch kind {
                case "upload":
                    self.log("upload", TF("act_received", name)); self.filesVersion += 1
                case "download":
                    self.log("download", TF("act_sent", name))
                case "delete":
                    self.log("trash", TF("act_deleted", name)); self.filesVersion += 1
                default: break
                }
            }
        }
        s.onFailure = { [weak self] msg in
            DispatchQueue.main.async {
                self?.stop()
                self?.errorText = TF("err_server", msg)
            }
        }

        do {
            try s.start(port: UInt16(clamping: port), serviceName: serviceName)
        } catch {
            errorText = TF("err_start", error.localizedDescription)
            return
        }

        server = s
        errorText = ""
        if let ip = ip {
            urlString = "http://\(ip):\(port)"
        } else {
            urlString = "http://localhost:\(port)"
            errorText = T("err_wifi")
        }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        log("play", T("act_started"))
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        urlString = ""
        UIApplication.shared.isIdleTimerDisabled = false
        log("stop", T("act_stopped"))
    }

    private func log(_ icon: String, _ text: String) {
        activity.insert(ActivityItem(icon: icon, text: text), at: 0)
        if activity.count > 50 { activity.removeLast() }
    }

    /// Bonjour service name: "<device>|<ip>|<port>" (max 63 bytes)
    static func serviceName(ip: String, port: Int) -> String {
        var name = UIDevice.current.name.replacingOccurrences(of: "|", with: " ")
        while name.utf8.count > 36 { name.removeLast() }
        if name.isEmpty { name = "iPhone" }
        return "\(name)|\(ip)|\(port)"
    }

    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
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
