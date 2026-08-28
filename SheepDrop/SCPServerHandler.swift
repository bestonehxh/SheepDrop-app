import CLibSSH
import Foundation

/// Server side of the SCP wire protocol, over one exec channel of the shared
/// SSH server. Lets a device pull with `copy scp://user@mac:port/file dest`
/// (sink runs `scp -f file`) or push a backup (`scp -t file`). Same port,
/// credentials and served root as the SFTP server — SCP is just a different
/// URL scheme on the same SSH connection.
///
/// Runs on the connection's worker thread (nonisolated). The classic rcp/scp
/// protocol: control bytes are `\0` acks; a file starts with a `C<mode> <size>
/// <name>\n` header.
nonisolated final class SCPServerHandler {
    private let channel: ssh_channel
    private let command: String
    private let root: URL
    /// Closure so the "Allow writes" toggle applies to live connections.
    private let allowWrites: @Sendable () -> Bool
    private let peer: String
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let onProgress: ServeProgress
    /// Unique per connection — see ServeTransfer.token.
    private let token = UUID().uuidString

    init(channel: ssh_channel, command: String, root: URL,
         allowWrites: @escaping @Sendable () -> Bool,
         peer: String, onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.channel = channel
        self.command = command
        self.root = root.standardizedFileURL
        self.allowWrites = allowWrites
        self.peer = peer
        self.onLog = onLog
        self.onProgress = onProgress
    }

    /// The transfer in flight on this connection, and whether it finished — so
    /// the `run()` defer can mark an interrupted transfer's own bar `.failed`
    /// (id-scoped) instead of clobbering whatever bar happens to be showing.
    private var lastActive: ServeTransfer?
    private var completed = false

    /// Push a progress update at most every 128 KB (and always at 100%), so a
    /// large firmware image doesn't flood the main actor.
    private func reportProgress(name: String, isUpload: Bool, done: Int64, total: Int64,
                                lastReported: inout Int64) {
        let t = ServeTransfer(token: token, peer: peer, name: name, isUpload: isUpload, done: done, total: total)
        lastActive = t
        if done - lastReported >= 128 * 1024 || done >= total {
            lastReported = done
            onProgress(t)
        }
    }

    /// Mark the bar complete; it is kept as a history row.
    private func reportDone(name: String, isUpload: Bool, total: Int64) {
        completed = true
        onProgress(ServeTransfer(token: token, peer: peer, name: name, isUpload: isUpload,
                                 done: total, total: total, state: .done))
    }

    func run() {
        defer {
            // If a transfer was in flight and never completed, fail ITS bar
            // (id-scoped); a browse/handshake-only connection touched no bar.
            if var t = lastActive, !completed { t.state = .failed; onProgress(t) }
            ssh_channel_send_eof(channel)
            ssh_channel_close(channel)
        }
        let args = command.split(separator: " ").map(String.init)
        let isSource = args.contains("-f")   // device pulls FROM us
        let isSink = args.contains("-t")     // device pushes TO us
        // The path is the whole tail after "scp" and its -x flags — joined, so
        // a filename containing spaces survives (args.last kept only the last
        // word of it).
        var rawPath = args.drop(while: { $0 == "scp" || $0.hasPrefix("-") })
            .joined(separator: " ")
        guard !rawPath.isEmpty else {
            fail("malformed scp command"); return
        }
        // libssh clients single-quote the exec path ('file'); OpenSSH doesn't.
        // Without stripping, a SheepDrop client pulling from a SheepDrop server
        // looked up a file literally named 'file' — and a push created one.
        if rawPath.count >= 2, rawPath.hasPrefix("'"), rawPath.hasSuffix("'") {
            rawPath = String(rawPath.dropFirst().dropLast())
        }
        guard let url = resolve(rawPath) else {
            fail("illegal path"); return
        }
        if isSource {
            sendFile(url)
        } else if isSink {
            receiveFile(intoDirectoryOrFile: url)
        } else {
            fail("unsupported scp mode")
        }
    }

    // MARK: - Source (device pulls firmware from us)

    private func sendFile(_ url: URL) {
        // Stream in 512 KB chunks — Data(contentsOf:) held the whole firmware
        // image (the primary pull use case) in RAM per connection.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
              let handle = try? FileHandle(forReadingFrom: url) else {
            sendError("no such file: \(url.lastPathComponent)")
            return
        }
        defer { try? handle.close() }
        guard readAck() else {
            log(isWrite: false, name: url.lastPathComponent, detail: "no initial ack from client", failed: true)
            return
        }
        let header = "C0644 \(size) \(url.lastPathComponent)\n"
        guard write(header), readAck() else {
            log(isWrite: false, name: url.lastPathComponent, detail: "client rejected file header", failed: true)
            return
        }
        var sent = 0
        var lastReported: Int64 = 0
        let name = url.lastPathComponent
        reportProgress(name: name, isUpload: false, done: 0, total: Int64(size), lastReported: &lastReported)
        while sent < size {
            guard let chunk = (try? handle.read(upToCount: 512 * 1024)).flatMap({ $0 }),
                  !chunk.isEmpty else { break }
            let ok = chunk.withUnsafeBytes { raw in
                writeBytes(raw.baseAddress, raw.count)
            }
            guard ok else { return }
            sent += chunk.count
            reportProgress(name: name, isUpload: false, done: Int64(sent), total: Int64(size), lastReported: &lastReported)
        }
        guard sent == size else { sendError("short read"); return }
        _ = writeByte(0)             // end-of-file marker
        _ = readAck()
        exit(0)
        reportDone(name: name, isUpload: false, total: Int64(size))
        log(isWrite: false, name: url.lastPathComponent, detail: "sent \(ByteFormat.string(Int64(sent)))")
    }

    // MARK: - Sink (device pushes a config backup to us)

    private func receiveFile(intoDirectoryOrFile url: URL) {
        guard allowWrites() else {
            sendError("writes are disabled on this server")
            log(isWrite: true, name: url.lastPathComponent, detail: "rejected (writes off)", failed: true)
            return
        }
        _ = writeByte(0)                       // tell the source we're ready
        guard let header = readLine(), header.hasPrefix("C") else {
            sendError("expected file header"); return
        }
        // C<mode> <size> <name>
        let parts = header.dropFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let size = Int(parts[1]) else {
            sendError("bad header"); return
        }
        let rawName = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        // SECURITY: the SCP header name is client-supplied. A device pushing to
        // a directory target (`scp -t .`) with a header like `C0644 4 ../../x`
        // would otherwise escape the served root — appendingPathComponent does
        // not resolve `..`. Reduce to a bare filename and reject traversal.
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            sendError("illegal filename"); return
        }
        var isDir: ObjCBool = false
        let destination = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            ? url.appendingPathComponent(name) : url
        // Defense in depth: the final destination must stay within the root.
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let destStd = destination.standardizedFileURL.path
        guard destStd == root.path || destStd.hasPrefix(rootPath) else {
            sendError("illegal path"); return
        }

        // Stream into a temp file; promote on success, discard on error —
        // accumulating in RAM held the whole push resident, and a partial
        // receive must not leave a half-written destination.
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".sheepdrop-scp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch { sendError("write failed"); return }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            sendError("write failed"); return
        }
        _ = writeByte(0)                       // ack the header

        var received = 0
        var lastReported: Int64 = 0
        reportProgress(name: name, isUpload: true, done: 0, total: Int64(size), lastReported: &lastReported)
        while received < size {
            guard let chunk = readBytes(min(512 * 1024, size - received)), !chunk.isEmpty else {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                sendError("short read"); return
            }
            do { try handle.write(contentsOf: chunk) } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                sendError("write failed"); return
            }
            received += chunk.count
            reportProgress(name: name, isUpload: true, done: Int64(received), total: Int64(size), lastReported: &lastReported)
        }
        _ = readByte()                         // trailing \0 from source
        try? handle.close()
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            _ = writeByte(0)                   // success
            exit(0)
            reportDone(name: name, isUpload: true, total: Int64(received))
            log(isWrite: true, name: name, detail: "received \(ByteFormat.string(Int64(received)))")
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            sendError("write failed")
        }
    }

    // MARK: - Path safety (shared rule with the SFTP handler)

    private func resolve(_ path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if candidate.path == root.path || candidate.path.hasPrefix(rootPath) {
            return candidate
        }
        return nil
    }

    // MARK: - Channel I/O

    private func write(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        return ssh_channel_write(channel, &bytes, UInt32(bytes.count)) == Int32(bytes.count)
    }

    @discardableResult
    private func writeByte(_ byte: UInt8) -> Bool {
        var b = byte
        return ssh_channel_write(channel, &b, 1) == 1
    }

    private func writeBytes(_ base: UnsafeRawPointer?, _ count: Int) -> Bool {
        guard let base else { return false }
        var offset = 0
        while offset < count {
            let n = ssh_channel_write(channel, base.advanced(by: offset), UInt32(count - offset))
            guard n > 0 else { return false }
            offset += Int(n)
        }
        return true
    }

    private func readByte() -> UInt8? {
        var b: UInt8 = 0
        return ssh_channel_read(channel, &b, 1, 0) == 1 ? b : nil
    }

    /// scp acks are a single `\0`; anything else is an error string.
    private func readAck() -> Bool {
        guard let b = readByte() else { return false }
        if b == 0 { return true }
        // 1 = warning, 2 = fatal — followed by a message line.
        _ = readLine()
        return false
    }

    private func readBytes(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let n = ssh_channel_read(channel, &buffer, UInt32(count), 0)
        guard n > 0 else { return nil }
        return Data(buffer[0..<Int(n)])
    }

    private func readLine() -> String? {
        var line = [UInt8]()
        while let b = readByte() {
            if b == 0x0A { break }
            line.append(b)
        }
        return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
    }

    private func sendError(_ message: String) {
        _ = writeByte(2)                       // fatal
        _ = write(message + "\n")
        exit(1)
        log(isWrite: false, name: message, detail: message, failed: true)
    }

    private func fail(_ message: String) {
        sendError(message)
    }

    private func exit(_ code: Int32) {
        ssh_channel_request_send_exit_status(channel, code)
    }

    private func log(isWrite: Bool, name: String, detail: String, failed: Bool = false) {
        onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: isWrite,
                           filename: name, detail: "SCP · " + detail, failed: failed))
    }
}
