import Foundation
import Network

/// Finds other iPhones running this app on the same Wi-Fi (Bonjour).
/// The host publishes its service name as "<device>|<ip>|<port>".
final class Discovery: ObservableObject {
    struct Peer: Identifiable, Hashable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }

    static let serviceType = "_lantransfer._tcp"

    @Published var peers: [Peer] = []
    private var browser: NWBrowser?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: Discovery.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [Peer] = []
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint {
                    let parts = name.components(separatedBy: "|")
                    if parts.count == 3, let port = Int(parts[2]) {
                        list.append(Peer(id: name, name: parts[0], host: parts[1], port: port))
                    }
                }
            }
            DispatchQueue.main.async {
                self?.peers = list.sorted { $0.name < $1.name }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers = []
    }
}
