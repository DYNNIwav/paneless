import Foundation

/// What `paneless --list-workspaces` prints. Only the running Paneless knows where windows are,
/// so the command line asks it: it posts `request` with a `token`, and Paneless writes the
/// listing as JSON to `replyURL(token:)`, which the command line reads and deletes.
struct WorkspaceListing: Codable, Equatable {
    struct Window: Codable, Equatable {
        let app: String
        let title: String
    }

    struct Workspace: Codable, Equatable {
        let number: Int
        let current: Bool
        let windows: [Window]
    }

    static let request = Notification.Name("com.paneless.listWorkspaces")

    let workspaces: [Workspace]

    /// The current workspace and every workspace with windows, in order, windows by app then title.
    init(windows: [Int: [Window]], current: Int) {
        let numbers = Set(windows.filter { !$0.value.isEmpty }.keys).union([current]).sorted()
        workspaces = numbers.map { n in
            let sorted = (windows[n] ?? []).sorted { ($0.app, $0.title) < ($1.app, $1.title) }
            return Workspace(number: n, current: n == current, windows: sorted)
        }
    }

    func text() -> String {
        workspaces.map { ws in
            let header = "Workspace \(ws.number) (\(ws.windows.count) windows)" + (ws.current ? " <- current" : "")
            let rows = ws.windows.map { "  " + ($0.title.isEmpty ? $0.app : "\($0.app): \($0.title)") }
            return ([header] + rows).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Where Paneless answers a request. The token must be a UUID, so a request can never
    /// make Paneless write anywhere but its own temporary directory.
    static func replyURL(token: String) -> URL? {
        guard let uuid = UUID(uuidString: token) else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paneless-workspaces-\(uuid.uuidString).json")
    }

    /// Asks the running Paneless for its listing. Nil when nothing answers within `timeout`.
    static func ask(timeout: TimeInterval = 1.5) -> WorkspaceListing? {
        let token = UUID().uuidString
        guard let reply = replyURL(token: token) else { return nil }
        DistributedNotificationCenter.default().postNotificationName(
            request, object: nil, userInfo: ["token": token], deliverImmediately: true)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: reply) {
                try? FileManager.default.removeItem(at: reply)
                return try? JSONDecoder().decode(WorkspaceListing.self, from: data)
            }
            usleep(20_000)
        }
        return nil
    }
}
