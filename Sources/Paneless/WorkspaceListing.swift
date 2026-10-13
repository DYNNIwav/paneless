import Foundation

/// What `paneless --list-workspaces` prints. Only the running Paneless knows where windows are,
/// so the command line asks it over `ListingSocket` and gets the listing back as JSON.
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

    /// Asks the running Paneless for its listing. Nil when nothing answers within `timeout`.
    static func ask(socket path: String = ListingSocket.defaultPath, timeout: TimeInterval = 1.5) -> WorkspaceListing? {
        guard var address = ListingSocket.address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return try? JSONDecoder().decode(WorkspaceListing.self, from: data)
    }
}
