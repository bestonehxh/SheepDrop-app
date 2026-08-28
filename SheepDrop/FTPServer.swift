import Foundation
import Network

/// Plain FTP server (RFC 959) so a device can `copy ftp://user@mac:port/…`.
/// Completes the client/server matrix (TFTP, SFTP, SCP already both ways).
///
/// FTP is CLEARTEXT — the login and files cross the wire unencrypted — so this
/// is for trusted lab segments; SFTP is the encrypted alternative. Serves the
/// same root, virtual login and write-gate as the other servers.
///
/// Port 21 needs root, so start() tries the preferred port and falls back to
/// 2121. Supports passive (PASV, a per-transfer listener) and active (PORT,
/// the server dials back) data connections. One control connection per client
/// on its own worker.
nonisolated final class FTPServer: @unchecked Sendable {
    static let fallbackPort: UInt16 = 2121

    struct Config: Sendable {
        var port: UInt16
        var username: String
        var password: String
        var rootPath: String
        var allowWrites: Bool
    }

    private let config: Config
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let queue = DispatchQueue(label: "sheepdrop.ftp.server")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]   // retain live sessions
    /// Read per STOR/DELE/MKD so flipping "Allow writes" applies to a running
    /// server (the captured `config.allowWrites` froze the toggle at start).
    private let allowWritesNow: @Sendable () -> Bool

    init(config: Config, allowWrites: (@Sendable () -> Bool)? = nil,
         onLog: @escaping @Sendable (TFTPLogEntry) -> Void) {
        self.config = config
        self.allowWritesNow = allowWrites ?? { config.allowWrites }
        self.onLog = onLog
    }

    func start() async throws -> UInt16 {
        do { return try await listen(on: config.port) }
        catch {
            guard config.port != Self.fallbackPort else { throw error }
            return try await listen(on: Self.fallbackPort)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            // Drain live sessions — a logged-in client must not keep browsing
            // a server the user just switched off.
            for session in sessions.values { session.close() }
            sessions.removeAll()
        }
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    continuation.resume(throwing: SFTPError(message: "bad port \(port)")); return
                }
                let candidate: NWListener
                do { candidate = try NWListener(using: .tcp, on: nwPort) }
                catch { continuation.resume(throwing: error); return }
                let resumed = Box(false)
                candidate.stateUpdateHandler = { state in
                    self.queue.async {
                        switch state {
                        case .ready where !resumed.value:
                            resumed.value = true; continuation.resume(returning: port)
                        case .failed(let error) where !resumed.value:
                            resumed.value = true; candidate.cancel()
                            continuation.resume(throwing: error)
                        case .cancelled where !resumed.value:
                            // Stopped before .ready — resume or the start() Task leaks.
                            resumed.value = true
                            continuation.resume(throwing: SFTPError(message: "server stopped before it began listening"))
                        default: break
                        }
                    }
                }
                candidate.newConnectionHandler = { connection in
                    self.queue.async {
                        let session = Session(server: self, control: connection)
                        self.sessions[ObjectIdentifier(session)] = session   // retain
                        session.begin()
                    }
                }
                listener?.cancel()
                listener = candidate
                candidate.start(queue: queue)
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T; init(_ v: T) { value = v }
    }

    fileprivate var conf: Config { config }
    fileprivate var writesAllowed: Bool { allowWritesNow() }
    fileprivate var workQueue: DispatchQueue { queue }
    fileprivate func log(_ entry: TFTPLogEntry) { onLog(entry) }
    fileprivate var rootURL: URL { URL(fileURLWithPath: config.rootPath) }
    fileprivate func sessionEnded(_ session: Session) {
        sessions[ObjectIdentifier(session)] = nil
    }

    fileprivate func resolve(_ cwd: String, _ arg: String) -> URL? {
        let path = arg.hasPrefix("/") ? arg : (cwd == "/" ? "/\(arg)" : "\(cwd)/\(arg)")
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        let base = rootURL.standardizedFileURL.path
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        return candidate.path == base || candidate.path.hasPrefix(basePrefix) ? candidate : nil
    }

    // MARK: - One control session

    fileprivate final class Session: @unchecked Sendable {
        // weak, not unowned: after stop() the AppModel drops the server while
        // a session's in-flight receive callback can still fire — an unowned
        // access there is a crash. Handlers bail out when the server is gone.
        private weak var server: FTPServer?
        private let control: NWConnection
        private var buffer = Data()
        private let peer: String

        private var authedUser: String?
        private var loggedIn = false
        private var cwd = "/"
        private var renameFrom: String?
        /// Pending data endpoint: either a PASV listener or a PORT target.
        private var pasvListener: NWListener?
        private var pendingData: NWConnection?
        private var portTarget: (host: String, port: UInt16)?

        init(server: FTPServer, control: NWConnection) {
            self.server = server
            self.control = control
            if case let .hostPort(host, port) = control.endpoint {
                peer = "\(host):\(port)"
            } else { peer = "?" }
        }

        func begin() {
            guard let server else { return }
            control.start(queue: server.workQueue)
            send("220 SheepDrop FTP ready\r\n")
            readLoop()
        }

        /// Server-initiated teardown (the user toggled the server off).
        func close() {
            control.cancel()
            pasvListener?.cancel()
            pendingData?.cancel()
        }

        private func readLoop() {
            control.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer.append(data)
                    while let line = takeLine() { handle(line) }
                }
                if isComplete || error != nil {
                    control.cancel()
                    pasvListener?.cancel()
                    server?.sessionEnded(self)
                    return
                }
                readLoop()
            }
        }

        private func takeLine() -> String? {
            guard let range = buffer.firstRange(of: Data([0x0A])) else { return nil }
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            return String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }

        private func send(_ text: String) {
            control.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        // MARK: Command dispatch

        private func handle(_ line: String) {
            guard let server else { control.cancel(); return }
            let space = line.firstIndex(of: " ")
            let verb = String(space.map { line[..<$0] } ?? Substring(line)).uppercased()
            let arg = space.map { String(line[line.index(after: $0)...]) } ?? ""

            switch verb {
            case "USER":
                authedUser = arg
                send("331 Password required\r\n")
            case "PASS":
                if authedUser == server.conf.username && arg == server.conf.password && !arg.isEmpty {
                    loggedIn = true
                    send("230 Logged in\r\n")
                } else {
                    server.log(TFTPLogEntry(time: Date(), peer: peer, isWrite: false,
                                            filename: "(auth)", detail: "FTP · login failed", failed: true))
                    send("530 Login incorrect\r\n")
                }
            case _ where !loggedIn:
                send("530 Please log in with USER and PASS\r\n")
            case "SYST": send("215 UNIX Type: L8\r\n")
            case "FEAT": send("211-Features:\r\n211 End\r\n")
            case "TYPE": send("200 Type set\r\n")
            case "PWD", "XPWD": send("257 \"\(cwd)\" is the current directory\r\n")
            case "CWD", "XCWD": changeDirectory(arg)
            case "CDUP", "XCUP":
                cwd = (cwd as NSString).deletingLastPathComponent
                if cwd.isEmpty { cwd = "/" }
                send("250 Directory changed\r\n")
            case "PASV": openPassive()
            case "PORT": openActive(arg)
            case "LIST", "NLST": listDirectory(arg, names: verb == "NLST")
            case "RETR": retrieve(arg)
            case "STOR": store(arg)
            case "SIZE": sendSize(arg)
            case "DELE": delete(arg)
            case "MKD", "XMKD": makeDirectory(arg)
            case "NOOP": send("200 OK\r\n")
            case "QUIT": send("221 Bye\r\n"); control.cancel()
            default: send("502 Command not implemented\r\n")
            }
        }

        // MARK: Navigation

        private func changeDirectory(_ arg: String) {
            guard let server, let url = server.resolve(cwd, arg),
                  directoryExists(url) else {
                send("550 No such directory\r\n"); return
            }
            let rel = url.path.dropFirst(server.rootURL.standardizedFileURL.path.count)
            cwd = rel.isEmpty ? "/" : String(rel)
            if !cwd.hasPrefix("/") { cwd = "/" + cwd }
            send("250 Directory changed\r\n")
        }

        private func directoryExists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        // MARK: Data channel setup

        private func openPassive() {
            guard let server else { return }
            pasvListener?.cancel(); pasvListener = nil; portTarget = nil
            guard let listener = try? NWListener(using: .tcp, on: .any) else {
                send("425 Cannot open data connection\r\n"); return
            }
            pasvListener = listener
            let q = server.workQueue
            listener.newConnectionHandler = { [weak self] connection in
                q.async {
                    connection.start(queue: q)
                    self?.pendingData = connection
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                q.async {
                    if case .ready = state, let port = listener.port?.rawValue,
                       let ip = LocalNetwork.ipv4(toReach: self.peerHost) ?? LocalNetwork.primaryIPv4() {
                        let h = ip.split(separator: ".").joined(separator: ",")
                        let p1 = Int(port) / 256, p2 = Int(port) % 256
                        self.send("227 Entering Passive Mode (\(h),\(p1),\(p2))\r\n")
                    }
                }
            }
            listener.start(queue: q)
        }

        private func openActive(_ arg: String) {
            let n = arg.split(separator: ",").compactMap { Int($0) }
            // Six octets, each 0–255 — the unchecked `UInt16(n[4]*256+n[5])`
            // used to TRAP on e.g. "PORT 1,2,3,4,999,999" from a logged-in
            // client, crashing the whole app.
            guard n.count == 6, n.allSatisfy({ (0...255).contains($0) }) else {
                send("501 Bad PORT\r\n"); return
            }
            let port = UInt16(n[4] * 256 + n[5])
            guard port > 0 else { send("501 Bad PORT\r\n"); return }
            portTarget = ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", port)
            pasvListener?.cancel(); pasvListener = nil; pendingData = nil
            send("200 PORT command successful\r\n")
        }

        /// Resolves the data connection (waits for the PASV connect, or dials
        /// the PORT target), runs `body`, then closes it.
        private func withData(_ body: @escaping @Sendable (NWConnection, @escaping @Sendable () -> Void) -> Void) {
            guard let server else { return }
            if let target = portTarget, let port = NWEndpoint.Port(rawValue: target.port) {
                let connection = NWConnection(host: .init(target.host), port: port, using: .tcp)
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        body(connection) { connection.cancel() }
                    }
                }
                connection.start(queue: server.workQueue)
                portTarget = nil
                return
            }
            // Passive: the client may not have connected yet — poll briefly.
            waitForPassive(attempt: 0, body)
        }

        private func waitForPassive(attempt: Int, _ body: @escaping @Sendable (NWConnection, @escaping @Sendable () -> Void) -> Void) {
            if let connection = pendingData {
                pendingData = nil
                let listener = pasvListener; pasvListener = nil
                body(connection) { connection.cancel(); listener?.cancel() }
                return
            }
            guard attempt < 100 else {
                send("425 Data connection not established\r\n"); return
            }
            server?.workQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForPassive(attempt: attempt + 1, body)
            }
        }

        private var peerHost: String {
            if case let .hostPort(host, _) = control.endpoint { return "\(host)" }
            return "127.0.0.1"
        }

        // MARK: Transfers

        private func listDirectory(_ arg: String, names: Bool) {
            let target = arg.isEmpty || arg.hasPrefix("-") ? cwd : arg
            guard let url = server?.resolve(cwd, target) else { send("550 No such path\r\n"); return }
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            let text = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { entry -> String in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if names { return entry.lastPathComponent }
                let isDir = values?.isDirectory ?? false
                let size = values?.fileSize ?? 0
                let perms = isDir ? "drwxr-xr-x" : "-rw-r--r--"
                return String(format: "%@ 1 sheepdrop sheepdrop %10d Jan  1 00:00 %@", perms, size, entry.lastPathComponent)
            }.joined(separator: "\r\n") + "\r\n"

            send("150 Here comes the directory listing\r\n")
            withData { connection, done in
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                    done(); self.send("226 Directory send OK\r\n")
                })
            }
        }

        private func retrieve(_ arg: String) {
            // Stream from disk in 512 KB chunks — `Data(contentsOf:)` held the
            // whole file (700 MB firmware!) in RAM and blocked the shared
            // server queue for the duration of the read, freezing every other
            // session's control replies.
            guard let server, let url = server.resolve(cwd, arg),
                  let handle = try? FileHandle(forReadingFrom: url) else {
                send("550 File not found\r\n"); return
            }
            send("150 Opening data connection\r\n")
            let peer = peer
            let q = server.workQueue
            let session = self
            withData { connection, done in
                let tally = Tally()
                @Sendable func pump() {
                    let chunk = (try? handle.read(upToCount: 512 * 1024)).flatMap { $0 }
                    guard let chunk, !chunk.isEmpty else {
                        try? handle.close()
                        done()
                        session.send("226 Transfer complete\r\n")
                        session.server?.log(TFTPLogEntry(time: Date(), peer: peer, isWrite: false,
                                                         filename: (arg as NSString).lastPathComponent,
                                                         detail: "FTP · sent \(ByteFormat.string(tally.bytes))", failed: false))
                        return
                    }
                    tally.bytes += Int64(chunk.count)
                    connection.send(content: chunk, completion: .contentProcessed { error in
                        if error != nil {
                            try? handle.close()
                            done()
                            session.send("426 Connection closed; transfer aborted\r\n")
                            session.server?.log(TFTPLogEntry(time: Date(), peer: peer, isWrite: false,
                                                             filename: (arg as NSString).lastPathComponent,
                                                             detail: "FTP · aborted", failed: true))
                            return
                        }
                        q.async { pump() }
                    })
                }
                pump()
            }
        }

        private func store(_ arg: String) {
            guard let server else { return }
            guard server.writesAllowed else {
                send("550 Writes are disabled\r\n"); return
            }
            guard let url = server.resolve(cwd, arg) else { send("550 Illegal path\r\n"); return }
            // Stream into a temp file next to the target; promote on clean EOF,
            // discard on error. The old accumulate-in-RAM version also treated
            // a mid-upload connection error exactly like completion — saving a
            // truncated file and replying 226, so both sides recorded a broken
            // backup as success.
            let tempURL = url.deletingLastPathComponent()
                .appendingPathComponent(".sheepdrop-upload-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tempURL) else {
                send("451 Write failed\r\n"); return
            }
            send("150 Ready to receive\r\n")
            let peer = peer
            let session = self
            withData { connection, done in
                let tally = Tally()
                @Sendable func fail(_ reply: String) {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    done()
                    session.send(reply)
                    session.server?.log(TFTPLogEntry(time: Date(), peer: peer, isWrite: true,
                                                     filename: (arg as NSString).lastPathComponent,
                                                     detail: "FTP · upload failed", failed: true))
                }
                @Sendable func pump() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            do {
                                try handle.write(contentsOf: data)
                                tally.bytes += Int64(data.count)
                            } catch {
                                fail("451 Write failed\r\n"); return
                            }
                        }
                        if error != nil {
                            // Data channel died mid-upload — the file is
                            // incomplete; discard it and say so.
                            fail("426 Connection closed; transfer aborted\r\n"); return
                        }
                        if isComplete {
                            try? handle.close()
                            done()
                            do {
                                if FileManager.default.fileExists(atPath: url.path) {
                                    try FileManager.default.removeItem(at: url)
                                }
                                try FileManager.default.moveItem(at: tempURL, to: url)
                                session.send("226 Transfer complete\r\n")
                                session.server?.log(TFTPLogEntry(time: Date(), peer: peer, isWrite: true,
                                                                 filename: (arg as NSString).lastPathComponent,
                                                                 detail: "FTP · received \(ByteFormat.string(tally.bytes))", failed: false))
                            } catch {
                                try? FileManager.default.removeItem(at: tempURL)
                                session.send("451 Write failed\r\n")
                            }
                            return
                        }
                        pump()
                    }
                }
                pump()
            }
        }

        /// Byte counter for streaming transfers — mutated only on the server
        /// queue (each callback schedules the next), boxed for @Sendable.
        private final class Tally: @unchecked Sendable { var bytes: Int64 = 0 }

        private func sendSize(_ arg: String) {
            guard let url = server?.resolve(cwd, arg),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
                send("550 Not found\r\n"); return
            }
            send("213 \(size)\r\n")
        }

        private func delete(_ arg: String) {
            guard let server, server.writesAllowed, let url = server.resolve(cwd, arg),
                  (try? FileManager.default.removeItem(at: url)) != nil else {
                send("550 Cannot delete\r\n"); return
            }
            send("250 Deleted\r\n")
        }

        private func makeDirectory(_ arg: String) {
            guard let server, server.writesAllowed, let url = server.resolve(cwd, arg),
                  (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil else {
                send("550 Cannot create\r\n"); return
            }
            send("257 Directory created\r\n")
        }
    }
}
