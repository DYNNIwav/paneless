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

    @Test func theDaemonOnlyAnswersIntoItsOwnTemporaryFiles() {
        let token = UUID().uuidString
        let reply = WorkspaceListing.replyURL(token: token)
        #expect(reply?.deletingLastPathComponent().standardizedFileURL
            == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL)
        #expect(reply?.lastPathComponent.contains(token) == true)
        #expect(WorkspaceListing.replyURL(token: "../../etc/passwd") == nil)
        #expect(WorkspaceListing.replyURL(token: "") == nil)
    }
}
