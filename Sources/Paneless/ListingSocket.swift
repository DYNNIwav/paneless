import Darwin
import Foundation

/// How `paneless --list-workspaces` asks the running Paneless for its listing. Window titles
/// are what Screen Recording guards, so Paneless only answers its own binary: it listens on a
/// socket in a directory only this user can enter, and checks the executable of every caller.
enum ListingSocket {
    /// In Application Support of the user's real home, not TMPDIR or HOME, which differ between
    /// processes: the app launched by launchd and a command run from a tool must find the same socket.
    static var defaultPath: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Application Support/Paneless/listing.sock"
    }

    /// True when the caller runs the very executable Paneless runs, following symlinks so
    /// `/opt/homebrew/bin/paneless` counts as the app it points to.
    static func peerAllowed(peer: String?, own: String?) -> Bool {
        guard let peer, let own, !peer.isEmpty, !own.isEmpty else { return false }
        return resolved(peer) == resolved(own)
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The executable of whoever is on the other end of `fd`. The audit token pins the exact
    /// process, so a caller cannot exit and hand its pid to another program in between.
    static func peerExecutablePath(_ fd: Int32) -> String? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    }

    /// Fills a socket address for `path`, or nil when the path is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Listens on `path` and hands `answer()` to callers running `allowed`, then hangs up.
    final class Server {
        private let path: String
        private let allowed: String?
        private let answer: () -> Data
        private let queue = DispatchQueue(label: "com.paneless.listing")
        private var source: DispatchSourceRead?

        init(path: String, allowed: String?, answer: @escaping () -> Data) {
            self.path = path
            self.allowed = allowed
            self.answer = answer
        }

        func start() throws {
            try makePrivateDirectory((path as NSString).deletingLastPathComponent)
            guard var address = ListingSocket.address(path) else { throw Failure("Socket path too long") }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure("socket") }
            unlink(path)  // a socket left by an earlier run
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                let failure = Failure("bind \(path)")
                close(fd)
                throw failure
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptCaller(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }

        func stop() {
            source?.cancel()
            source = nil
            unlink(path)
        }

        private func acceptCaller(_ listener: Int32) {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var limit = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            let peer = ListingSocket.peerExecutablePath(fd)
            guard ListingSocket.peerAllowed(peer: peer, own: allowed) else {
                panelessLog("Refused --list-workspaces from \(peer ?? "unknown")")
                return
            }
            let data = answer()
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }

        /// Creates `dir` readable only by this user, or makes sure an existing one is ours.
        private func makePrivateDirectory(_ dir: String) throws {
            if mkdir(dir, 0o700) != 0 {
                guard errno == EEXIST else { throw Failure("mkdir \(dir)") }
                var info = stat()
                guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                    throw Failure("\(dir) is not a directory of this user")
                }
            }
            guard chmod(dir, 0o700) == 0 else { throw Failure("chmod \(dir)") }
        }
    }
}
