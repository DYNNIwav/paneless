import Foundation
import Testing
@testable import Paneless

@Suite struct WorkspaceListingTests {
    @Test func listsTheCurrentWorkspaceAndEveryOneWithWindows() {
        let listing = WorkspaceListing(windows: [
            3: [.init(app: "Notes", title: "Shopping")],
            1: [.init(app: "Safari", title: "Apple"), .init(app: "Mail", title: "")],
            5: [],
        ], current: 2)
        #expect(listing.text() == """
        Workspace 1 (2 windows)
          Mail
          Safari: Apple
        Workspace 2 (0 windows) <- current
        Workspace 3 (1 windows)
          Notes: Shopping
        """)
    }

    @Test func survivesTheTripFromDaemonToCommandLine() throws {
        let listing = WorkspaceListing(windows: [1: [.init(app: "Notes", title: "Shopping")]], current: 1)
        let decoded = try JSONDecoder().decode(WorkspaceListing.self, from: JSONEncoder().encode(listing))
        #expect(decoded == listing)
    }

    @Test func onlyThePanelessBinaryItselfMayReadTheListing() {
        let own = "/Applications/Paneless.app/Contents/MacOS/Paneless"
        #expect(ListingSocket.peerAllowed(peer: own, own: own))
        #expect(!ListingSocket.peerAllowed(peer: "/usr/bin/python3", own: own))
        #expect(!ListingSocket.peerAllowed(peer: nil, own: own))
        #expect(!ListingSocket.peerAllowed(peer: own, own: nil))
        #expect(!ListingSocket.peerAllowed(peer: "", own: ""))
    }

    @Test func theSocketLivesInAPrivateDirectory() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/sock/listing.sock"
        let server = ListingSocket.Server(path: path, allowed: "/nowhere") { Data() }
        try server.start()
        defer { server.stop() }
        #expect(permissions(of: dir + "/sock") == 0o700)
        #expect(permissions(of: path) == 0o600)
        #expect(ListingSocket.defaultPath.hasSuffix("/Library/Application Support/Paneless/listing.sock"))
    }

    @Test func aStaleSocketIsReplaced() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/listing.sock"
        try ListingSocket.Server(path: path, allowed: "/nowhere") { Data() }.start()
        let server = ListingSocket.Server(path: path, allowed: "/nowhere") { Data() }
        try server.start()
        server.stop()
    }

    @Test func theCommandLineGetsTheListingFromTheDaemon() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/listing.sock"
        let listing = WorkspaceListing(windows: [1: [.init(app: "Notes", title: "Shopping")]], current: 1)
        let server = ListingSocket.Server(path: path, allowed: ListingSocket.executablePath(of: getpid())) {
            try! JSONEncoder().encode(listing)
        }
        try server.start()
        defer { server.stop() }
        #expect(WorkspaceListing.ask(socket: path) == listing)
    }

    @Test func anyOtherProgramGetsNothing() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/listing.sock"
        let server = ListingSocket.Server(path: path, allowed: "/Applications/Paneless.app/Contents/MacOS/Paneless") {
            Data("secret".utf8)
        }
        try server.start()
        defer { server.stop() }
        #expect(WorkspaceListing.ask(socket: path) == nil)
    }

    @Test func nobodyListeningMeansNotRunning() {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let started = Date()
        #expect(WorkspaceListing.ask(socket: dir + "/listing.sock") == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    // Short, because a socket path may be at most 104 bytes.
    private func temporaryDirectory() -> String {
        let dir = "/tmp/pl-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func permissions(of path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }
}
