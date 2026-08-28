import Foundation
import Network

/// Minimal FTP client (RFC 959, passive mode, binary transfers) over
/// Network.framework. macOS has no usable built-in FTP client anymore
/// (URLSession's FTP support is deprecated and list-only), so this is a small
/// hand-rolled one — enough to browse, pull firmware and push a backup, the
/// same surface the SFTP worker offers.
///
/// One control connection on its own serial queue; a fresh data connection per
/// transfer (PASV). Every public method is async and hops onto the queue.
nonisolated final class FTPWorker: @unchecked Sendable {
    struct Config: Sendable {
        var host: String
        var port: Int
        var username: String
        var password: String?
    }

    private let queue = DispatchQueue(label: "sheepdrop.ftp.control")
    private var control: NWConnection?
    private var buffer = Data()          // control-line read buffer (op-confined)

    // MARK: - Async surface

    func connect(_ config: Config) async throws {
        try await serialized { try await $0.doConnect(config) }
    }

    func disconnect() {
        // Joins the same chain as every other operation so it can't tear the
        // connection down under a transfer that's mid-flight.
        chainLock.lock()
        let previous = chainTail
        let task = Task { [self] in
            await previous?.value
            control?.cancel()
            control = nil
            buffer.removeAll()
        }
        chainTail = task
        chainLock.unlock()
    }

    func currentDirectory() async throws -> String {
        try await serialized { try await $0.doPWD() }
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await serialized { try await $0.doList(path) }
    }

    func download(remotePath: String, to localURL: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await serialized { try await $0.doDownload(remotePath, localURL, progress) }
    }

    func upload(localURL: URL, to remotePath: String,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await serialized { try await $0.doUpload(localURL, remotePath, progress) }
    }

    /// Strict operation chain. The old `queue.async { Task { … } }` wrapper
    /// only serialized *task creation* — the async bodies ran concurrently on
    /// the cooperative pool, so a refresh clicked during a download interleaved
    /// two PASV/LIST/RETR exchanges on the one control connection and raced on
    /// `buffer`. Each operation now runs strictly after the previous one.
    private let chainLock = NSLock()
    private var chainTail: Task<Void, Never>?

    private func serialized<T: Sendable>(_ body: @escaping @Sendable (FTPWorker) async throws -> T) async throws -> T {
        try await enqueue(body).value
    }

    /// Synchronous chain append (NSLock isn't usable from async contexts).
    private func enqueue<T: Sendable>(_ body: @escaping @Sendable (FTPWorker) async throws -> T) -> Task<T, Error> {
        chainLock.lock()
        defer { chainLock.unlock() }
        let previous = chainTail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await body(self)
        }
        chainTail = Task { _ = try? await task.value }
        return task
    }

    // MARK: - Session

    private func doConnect(_ config: Config) async throws {
        guard control == nil else { return }
        buffer.removeAll()          // stale bytes from a previously dropped session
        let connection = try await openConnection(host: config.host, port: config.port)
        control = connection
        do {
            _ = try await readReply()                       // 220 welcome
            try await command("USER \(config.username)", expect: [220, 230, 331])
            if let password = config.password {
                try await command("PASS \(password)", expect: [230, 202])
            }
            try await command("TYPE I", expect: [200])       // binary
        } catch {
            // A failed login must tear the half-open connection down — leaving
            // `control` set made every retry return from the `guard` above
            // without authenticating: the tab showed "connected" and every
            // command then failed with 530.
            connection.cancel()
            control = nil
            buffer.removeAll()
            throw error
        }
    }

    private func doPWD() async throws -> String {
        let reply = try await command("PWD", expect: [257])
        // 257 "/path" is current directory
        if let start = reply.firstIndex(of: "\""),
           let end = reply[reply.index(after: start)...].firstIndex(of: "\"") {
            return String(reply[reply.index(after: start)..<end])
        }
        return "/"
    }

    private func doList(_ path: String) async throws -> [FileEntry] {
        let data = try await withDataConnection { dataConn in
            try await self.command("LIST \(path)", expect: [125, 150])
            let bytes = try await self.readAll(dataConn)
            try await self.expectTransferComplete()
            return bytes
        }
        return Self.parseList(String(decoding: data, as: UTF8.self))
    }

    /// The data channel tolerates errors by design (some servers RST instead
    /// of FIN), so the post-transfer control reply is the ONLY completion
    /// check — and it must actually be checked: a 426/451/552 here means the
    /// transfer failed even though the data stream "ended".
    private func expectTransferComplete() async throws {
        let reply = try await readReply()
        let code = Int(reply.prefix(3)) ?? -1
        guard (200..<300).contains(code) else {
            throw SFTPError(message: "FTP \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func doDownload(_ remotePath: String, _ localURL: URL,
                            _ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = (try? await size(remotePath)) ?? 0
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError(message: "cannot write \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }
        _ = try await withDataConnection { dataConn in
            try await self.command("RETR \(remotePath)", expect: [125, 150])
            var done: Int64 = 0
            // A data-channel error means the server closed the stream (some
            // servers RST instead of FIN); the control 226 below is the
            // authoritative completion signal, so stop reading on either.
            while let chunk = try? await self.receive(dataConn) {
                try handle.write(contentsOf: chunk)
                done += Int64(chunk.count)
                progress(done, total)
            }
            try await self.expectTransferComplete()
            return Data()
        }
    }

    private func doUpload(_ localURL: URL, _ remotePath: String,
                          _ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError(message: "cannot read \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }
        let total = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        _ = try await withDataConnection { dataConn in
            try await self.command("STOR \(remotePath)", expect: [125, 150])
            var done: Int64 = 0
            // 512 KB chunks — Network.framework segments internally, and each
            // chunk costs an awaited continuation round-trip, so tiny chunks
            // just multiply overhead.
            while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try await self.send(dataConn, chunk)
                done += Int64(chunk.count)
                progress(done, total)
            }
            dataConn.cancel()                            // EOF to the server
            try await self.expectTransferComplete()
            return Data()
        }
    }

    private func size(_ path: String) async throws -> Int64 {
        let reply = try await command("SIZE \(path)", expect: [213])
        let digits = reply.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return Int64(digits) ?? 0
    }

    // MARK: - Data connection (passive)

    private func withDataConnection<T: Sendable>(_ body: @escaping @Sendable (NWConnection) async throws -> T) async throws -> T {
        let reply = try await command("PASV", expect: [227])
        guard let (host, port) = Self.parsePASV(reply) else {
            throw SFTPError(message: "could not parse passive-mode reply")
        }
        let data = try await openConnection(host: host, port: port)
        defer { data.cancel() }
        return try await body(data)
    }

    // MARK: - Control protocol

    @discardableResult
    private func command(_ line: String, expect codes: [Int]) async throws -> String {
        guard let control else { throw SFTPError(message: "not connected") }
        try await send(control, Data((line + "\r\n").utf8))
        let reply = try await readReply()
        let code = Int(reply.prefix(3)) ?? -1
        guard codes.contains(code) else {
            let isAuth = code == 530 || code == 430
            throw SFTPError(message: "FTP \(reply.trimmingCharacters(in: .whitespacesAndNewlines))",
                            isAuthFailure: isAuth)
        }
        return reply
    }

    /// Reads one full FTP reply (handles multi-line "123-…\n…\n123 end").
    private func readReply() async throws -> String {
        guard let control else { throw SFTPError(message: "not connected") }
        while true {
            if let line = takeLine() {
                if line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == " ",
                   Int(line.prefix(3)) != nil {
                    return line
                }
                // multi-line continuation — keep reading until "NNN " line.
                if line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
                    let code = String(line.prefix(3))
                    return try await readUntilFinal(code: code, first: line)
                }
                continue
            }
            guard let chunk = try await receive(control), !chunk.isEmpty else {
                throw SFTPError(message: "control connection closed")
            }
            buffer.append(chunk)
        }
    }

    private func readUntilFinal(code: String, first: String) async throws -> String {
        guard let control else { throw SFTPError(message: "not connected") }
        var collected = first
        while true {
            if let line = takeLine() {
                collected += "\n" + line
                if line.hasPrefix(code + " ") { return collected }
                continue
            }
            guard let chunk = try await receive(control), !chunk.isEmpty else {
                throw SFTPError(message: "control connection closed")
            }
            buffer.append(chunk)
        }
    }

    private func takeLine() -> String? {
        guard let range = buffer.firstRange(of: Data([0x0D, 0x0A]))
            ?? buffer.firstRange(of: Data([0x0A])) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return String(decoding: lineData, as: UTF8.self)
    }

    // MARK: - NWConnection helpers

    private func openConnection(host: String, port: Int) async throws -> NWConnection {
        // UInt16(exactly:) — the trapping UInt16(port) ran BEFORE the failable
        // guard, so an out-of-range port (typo in Quick Connect, or a malicious
        // PASV reply) crashed the app instead of erroring.
        guard let raw = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: raw), raw > 0 else {
            throw SFTPError(message: "bad port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.once() { continuation.resume() }
                case .failed(let error):
                    if resumed.once() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.once() { continuation.resume(throwing: SFTPError(message: "connection cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return connection
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Returns nil only at real EOF (isComplete). A spurious empty-but-open
    /// read loops internally, so callers can treat nil as "the stream ended"
    /// — a plain `!chunk.isEmpty` check would truncate a listing/transfer.
    private func receive(_ connection: NWConnection) async throws -> Data? {
        while true {
            let result: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: Data()) }  // keep waiting
                }
            }
            if let result {
                if result.isEmpty { continue }   // open but nothing yet
                return result
            }
            return nil                           // EOF
        }
    }

    private func readAll(_ connection: NWConnection) async throws -> Data {
        var all = Data()
        // Tolerate a data-channel reset (see doDownload) — the control 226
        // reply after this is the real completion check.
        while let chunk = try? await receive(connection) {
            all.append(chunk)
        }
        return all
    }

    private final class ResumeGuard: @unchecked Sendable {
        private var done = false
        func once() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Parsing

    /// Parses "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)".
    static func parsePASV(_ reply: String) -> (host: String, port: Int)? {
        guard let open = reply.firstIndex(of: "("),
              let close = reply.firstIndex(of: ")") else { return nil }
        let nums = reply[reply.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        // Each field is one octet — reject out-of-range values instead of
        // letting a bogus reply build a nonsense host or an overflowing port.
        guard nums.count == 6, nums.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let host = "\(nums[0]).\(nums[1]).\(nums[2]).\(nums[3])"
        let port = nums[4] * 256 + nums[5]
        guard port > 0 else { return nil }
        return (host, port)
    }

    /// Parses Unix `ls -l`-style LIST output into FileEntry rows. Splits on the
    /// LF *byte*, not on Characters — LIST lines end in CRLF, and Swift treats
    /// "\r\n" as ONE Character that equals neither "\n" nor "\r", so a
    /// Character-level split would collapse the whole listing into one line
    /// (the recurring CRLF trap; see SheepText's CLAUDE.md).
    static func parseList(_ text: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        let lines = text.utf8.split(separator: 0x0A).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let first = line.first else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9, "-dl".contains(first) else { continue }
            let isDir = first == "d"
            let size = Int64(fields[4]) ?? 0
            // name is everything after the 8th field (perms, links, owner,
            // group, size, month, day, time/year, name…).
            let name = fields[8...].joined(separator: " ")
            if name == "." || name == ".." { continue }
            if first == "l" {
                // symlink: "name -> target"; keep just the name. Listed as a
                // FILE: a file symlink can then be downloaded (as a "dir" it
                // could neither be entered — CWD into a file 550s — nor
                // downloaded, since the chevron requires !isDirectory). A
                // dir symlink's download fails with a clear 550 instead.
                let display = name.components(separatedBy: " -> ").first ?? name
                entries.append(FileEntry(name: display, isDirectory: false, size: 0, modified: nil))
                continue
            }
            entries.append(FileEntry(name: name, isDirectory: isDir, size: size, modified: nil))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
