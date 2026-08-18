import Cocoa

/// Tells the user when a newer Paneless has been released.
///
/// Deliberately does not update anything. Paneless is installed through a Homebrew
/// cask, and an app that replaces itself leaves brew believing a version is installed
/// that is not, so the next `brew upgrade` has nothing sensible to do. Checking and
/// saying so keeps brew the single source of truth about what is installed.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "DYNNIwav/paneless"
    private let interval: TimeInterval = 60 * 60 * 24
    private let lastCheckKey = "UpdateCheckerLastCheck"

    /// Set when a newer release exists, so the menu can offer it.
    private(set) var availableVersion: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check at most once a day, and never block anything on the result.
    func checkIfDue(then completion: @escaping () -> Void) {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > interval else { return }
        check(then: completion)
    }

    func check(then completion: @escaping () -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            DispatchQueue.main.async {
                self.availableVersion = Self.isNewer(latest, than: self.currentVersion) ? latest : nil
                if let v = self.availableVersion {
                    panelessLog("Update available: \(v) (running \(self.currentVersion))")
                }
                completion()
            }
        }.resume()
    }

    /// Compare dotted versions numerically, so 0.10.0 counts as newer than 0.9.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// What the user should actually run, when brew owns the install.
    var upgradeCommand: String { "brew upgrade --cask paneless" }

    /// How this copy of Paneless got here, which decides what we may offer to do
    /// about an update.
    enum InstallSource {
        /// Homebrew owns it, so we must not replace the app ourselves: brew would go on
        /// believing the old version is installed.
        case homebrew
        /// Downloaded and dragged in, so nothing else is tracking it and pointing at a
        /// download is the whole job.
        case direct
    }

    var installSource: InstallSource {
        // A cask leaves its own directory behind, on either Homebrew prefix.
        for prefix in ["/opt/homebrew", "/usr/local"] {
            if FileManager.default.fileExists(atPath: "\(prefix)/Caskroom/paneless") {
                return .homebrew
            }
        }
        return .direct
    }

    var downloadURL: URL? {
        URL(string: "https://github.com/\(repo)/releases/latest")
    }
}
