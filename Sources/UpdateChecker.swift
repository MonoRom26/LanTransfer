import Foundation
import UIKit

enum UpdateConfig {
    static let owner = "MonoRom26"      // your GitHub username
    static let repo = "LanTransfer"     // your repository name
}

/// Checks the latest GitHub release and compares it with this app's version.
final class UpdateChecker: ObservableObject {
    enum State { case idle, checking, upToDate, available, failed }

    @Published var state: State = .idle
    @Published var showAlert = false
    @Published var latestVersion = ""

    private var releaseURL: URL?
    private var didAutoCheck = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var releasesPageURL: URL {
        URL(string: "https://github.com/\(UpdateConfig.owner)/\(UpdateConfig.repo)/releases/latest")
            ?? URL(string: "https://github.com")!
    }

    func openRelease() {
        UIApplication.shared.open(releaseURL ?? releasesPageURL)
    }

    /// Runs once per app launch, silently (only shows an alert if a new version exists)
    func autoCheck() {
        guard !didAutoCheck else { return }
        didAutoCheck = true
        check(manual: false)
    }

    func check(manual: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(UpdateConfig.owner)/\(UpdateConfig.repo)/releases/latest") else { return }
        state = .checking
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LanTransfer", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data,
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    self.state = manual ? .failed : .idle
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if let page = obj["html_url"] as? String { self.releaseURL = URL(string: page) }
                if Self.isNewer(latest, than: Self.currentVersion) {
                    self.latestVersion = latest
                    self.state = .available
                    self.showAlert = true
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// "1.10" is newer than "1.9"; compares number by number
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
