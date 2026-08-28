import Foundation
import Network

/// One TFTP transfer as it appears in the server panel's log.
struct TFTPLogEntry: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let peer: String
    let isWrite: Bool
    let filename: String
    var detail: String
    var failed: Bool
}

/// A transfer currently in flight on any built-in server (TFTP/SFTP/SCP/FTP),
/// shown as a live progress bar under the Serve view's request log. `total == 0`
/// means the size is unknown (indeterminate bar). `isUpload` is from the
/// device's point of view: true = the device is pushing a file TO this Mac.
struct ServeTransfer: Identifiable, Equatable, Sendable {
    enum State: Sendable { case active, done, failed }
    let peer: String
    let name: String
    let isUpload: Bool
    var done: Int64
    var total: Int64
    var state: State = .active
    /// peer+name, so repeated progress ticks for one transfer coalesce.
    var id: String { peer + "\u{1}" + name }
}

/// Progress sink passed to every server:
/// - a `.active` value updates the live bar as bytes move;
/// - a `.done` value marks the bar complete and it is KEPT as history;
/// - `nil` means "the in-flight transfer ended" — if the shown one is still
///   `.active` it was interrupted (→ `.failed`); a `.done` one stays put.
typealias ServeProgress = @Sendable (ServeTransfer?) -> Void

/// TFTP server (RFC 1350 + blksize/tsize/timeout options, RFC 2347–2349).
/// Built for the network-device workflow: a switch runs
/// `copy tftp://<mac>[:port]/file …` and pulls from the root folder.
///
/// Design notes:
/// - Network.framework's UDP NWListener hands us one NWConnection per remote
///   endpoint, so every transfer keeps its own flow. Replies go out from the
///   listener port itself (a legal TID choice — clients lock onto the source
///   port of the first OACK/DATA they see).
/// - Port 69 needs root; start() tries the preferred port and falls back to
///   6969. AOS-CX copy URLs accept an explicit :port, so the fallback is a
///   first-class citizen, not a degraded mode.
/// - Everything runs on one serial queue; the UI hears about transfers only
///   through the @Sendable log callback.
nonisolated final class TFTPServer: @unchecked Sendable {
    static let fallbackPort: UInt16 = 6969

    private let queue = DispatchQueue(label: "sheepdrop.tftp.server")
    private let root: URL
    private let allowWrites: @Sendable () -> Bool
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    fileprivate let onProgress: ServeProgress

    // Queue-confined.
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]

    init(root: URL,
         allowWrites: @escaping @Sendable () -> Bool,
         onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.root = root
        self.allowWrites = allowWrites
        self.onLog = onLog
        self.onProgress = onProgress
    }

    /// Binds and returns the actual port (preferred, or the fallback).
    func start(preferredPort: UInt16 = 69) async throws -> UInt16 {
        do {
            return try await listen(on: preferredPort)
        } catch {
            guard preferredPort != Self.fallbackPort else { throw error }
            return try await listen(on: Self.fallbackPort)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.cancel() }
            sessions.removeAll()
        }
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    continuation.resume(throwing: SFTPError(message: "bad port \(port)"))
                    return
                }
                let candidate: NWListener
                do {
                    candidate = try NWListener(using: .udp, on: nwPort)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // resume exactly once across ready/failed.
                let resumed = Box(false)
                candidate.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async {
                        switch state {
                        case .ready:
                            if !resumed.value {
                                resumed.value = true
                                continuation.resume(returning: port)
                            }
                        case .failed(let error):
                            if !resumed.value {
                                resumed.value = true
                                candidate.cancel()
                                continuation.resume(throwing: error)
                            } else {
                                self.listener = nil
                            }
                        default:
                            break
                        }
                    }
                }
                candidate.newConnectionHandler = { [weak self] connection in
                    self?.queue.async { self?.accept(connection) }
                }
                listener?.cancel()
                listener = candidate
                candidate.start(queue: queue)
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(server: self, connection: connection)
        sessions[ObjectIdentifier(session)] = session
        session.begin()
    }

    fileprivate func sessionEnded(_ session: Session) {
        sessions[ObjectIdentifier(session)] = nil
    }

    fileprivate func log(peer: String, isWrite: Bool, filename: String,
                         detail: String, failed: Bool) {
        onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: isWrite,
                           filename: filename, detail: detail, failed: failed))
    }

    fileprivate func fileURL(for rawName: String) -> URL? {
        let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        guard !name.isEmpty, !name.contains("..") else { return nil }
        return root.appendingPathComponent(name)
    }

    fileprivate var rootURL: URL { root }
    fileprivate var writesAllowed: Bool { allowWrites() }
    fileprivate var serverQueue: DispatchQueue { queue }

    // MARK: - One transfer

    // Queue-confined like its owner — every callback hops onto serverQueue.
    fileprivate final class Session: @unchecked Sendable {
        private unowned let server: TFTPServer
        private let connection: NWConnection
        private let peer: String

        private var isWrite = false
        private var filename = ""
        private var blockSize = 512
        // Reads stream from disk block-by-block — a 700 MB firmware image
        // must not be resident in RAM for the whole transfer.
        private var readHandle: FileHandle?
        private var fileSize: Int = 0
        private var writeHandle: FileHandle?
        private var writtenBytes: Int = 0
        private var expectedTotal: Int?
        private var currentBlock: UInt16 = 0   // last block sent (read) / acked (write)
        private var lastPacket = Data()
        private var retries = 0
        private var generation = 0
        private var finished = false
        private var sentFinal = false

        init(server: TFTPServer, connection: NWConnection, peerOverride: String? = nil) {
            self.server = server
            self.connection = connection
            if case let .hostPort(host, port) = connection.endpoint {
                self.peer = "\(host):\(port)"
            } else {
                self.peer = peerOverride ?? "?"
            }
        }

        func begin() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(nil) }
            }
            connection.start(queue: server.serverQueue)
            receiveNext(first: true)
        }

        func cancel() {
            finished = true
            connection.cancel()
        }

        private func receiveNext(first: Bool = false) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, !self.finished else { return }
                if error != nil { self.finish(nil); return }
                guard let data, data.count >= 2 else {
                    // On the FIRST datagram a runt packet must still finish the
                    // session — returning silently leaked it in `sessions`
                    // until server stop.
                    if first { self.finish(nil) } else { self.receiveNext() }
                    return
                }
                self.handle(packet: data, first: first)
            }
        }

        private func handle(packet: Data, first: Bool) {
            let opcode = UInt16(packet[packet.startIndex]) << 8 | UInt16(packet[packet.startIndex + 1])
            switch opcode {
            case 1, 2: // RRQ / WRQ
                guard first else { receiveNext(); return }
                startRequest(packet: packet, write: opcode == 2)
            case 3: // DATA (write path)
                handleData(packet)
            case 4: // ACK (read path)
                handleAck(packet)
            case 5: // ERROR from peer
                let message = String(data: packet.dropFirst(4).prefix(while: { $0 != 0 }), encoding: .utf8) ?? "error"
                finish("peer error: \(message)", failed: true)
            default:
                receiveNext()
            }
        }

        // MARK: Request

        private func startRequest(packet: Data, write: Bool) {
            var fields: [String] = []
            var current = Data()
            for byte in packet.dropFirst(2) {
                if byte == 0 {
                    fields.append(String(decoding: current, as: UTF8.self))
                    current.removeAll()
                } else {
                    current.append(byte)
                }
            }
            guard fields.count >= 2 else { sendError(4, "malformed request"); return }
            filename = fields[0]
            isWrite = write
            let mode = fields[1].lowercased()
            guard mode == "octet" || mode == "netascii" else {
                sendError(4, "mode \(mode) not supported")
                return
            }

            // Options (blksize / tsize / timeout) — echo what we accept.
            var options: [(String, String)] = []
            var index = 2
            while index + 1 < fields.count {
                options.append((fields[index].lowercased(), fields[index + 1]))
                index += 2
            }

            guard let url = server.fileURL(for: filename) else {
                sendError(2, "illegal filename")
                return
            }

            if isWrite {
                guard server.writesAllowed else {
                    sendError(2, "writes are disabled on this server")
                    return
                }
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    sendError(2, "cannot create file")
                    return
                }
                writeHandle = handle
            } else {
                guard let handle = try? FileHandle(forReadingFrom: url),
                      let size = try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? Int else {
                    sendError(1, "file not found")
                    return
                }
                readHandle = handle
                fileSize = size
            }

            var acked: [(String, String)] = []
            for (name, value) in options {
                switch name {
                case "blksize":
                    let requested = Int(value) ?? 512
                    blockSize = min(max(requested, 8), 8192)
                    acked.append((name, "\(blockSize)"))
                case "tsize":
                    if isWrite {
                        expectedTotal = Int(value)
                        acked.append((name, value))
                    } else {
                        acked.append((name, "\(fileSize)"))
                    }
                case "timeout":
                    acked.append((name, value))
                default:
                    break
                }
            }

            server.log(peer: peer, isWrite: isWrite, filename: filename,
                       detail: "started", failed: false)

            if !acked.isEmpty {
                var oack = Data([0, 6])
                for (name, value) in acked {
                    oack.append(contentsOf: name.utf8); oack.append(0)
                    oack.append(contentsOf: value.utf8); oack.append(0)
                }
                lastPacket = oack
                send(oack)
                // read: wait for ACK 0 → then DATA 1. write: peer sends DATA 1.
            } else if isWrite {
                sendAck(0)
            } else {
                sendDataBlock(1)
            }
            receiveNext()
        }

        // MARK: Read path (device pulls)

        private func handleAck(_ packet: Data) {
            guard !isWrite else { receiveNext(); return }
            // receiveNext only guarantees 2 bytes — a truncated ACK from a
            // buggy client used to crash on the block-number subscript.
            guard packet.count >= 4 else { receiveNext(); return }
            let block = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
            retries = 0
            if sentFinal && block == currentBlock {
                reportDone(done: fileSize, isUpload: false)
                finish("sent \(ByteFormat.string(Int64(fileSize)))")
                return
            }
            sendDataBlock(block &+ 1)
            receiveNext()
        }

        private func sendDataBlock(_ block: UInt16) {
            guard let handle = readHandle else { return }
            // Block numbers wrap at 65535 (RFC allows it; needed past
            // blksize×65535 bytes) — track the absolute offset ourselves.
            let offset = sendOffset(for: block)
            guard offset <= fileSize,
                  let chunk = try? { () -> Data in
                      try handle.seek(toOffset: UInt64(offset))
                      return try handle.read(upToCount: blockSize) ?? Data()
                  }() else {
                sendError(0, "read failed")
                return
            }
            var packet = Data([0, 3, UInt8(block >> 8), UInt8(block & 0xFF)])
            packet.append(chunk)
            currentBlock = block
            if chunk.count < blockSize { sentFinal = true }
            lastPacket = packet
            send(packet)
            reportProgress(done: min(offset + chunk.count, fileSize), total: fileSize, isUpload: false)
            scheduleRetransmit()
        }

        // Queue-confined; throttled to ~128 KB so a big image doesn't flood.
        private var lastReported = 0
        private func reportProgress(done: Int, total: Int, isUpload: Bool) {
            if done - lastReported >= 128 * 1024 || (total > 0 && done >= total) {
                lastReported = done
                server.onProgress(ServeTransfer(peer: peer, name: filename, isUpload: isUpload,
                                                done: Int64(done), total: Int64(total)))
            }
        }

        /// Mark complete; kept as a history row (finish()'s onProgress(nil)
        /// finalizer leaves a `.done` in place).
        private func reportDone(done: Int, isUpload: Bool) {
            server.onProgress(ServeTransfer(peer: peer, name: filename, isUpload: isUpload,
                                            done: Int64(done), total: Int64(done), state: .done))
        }

        /// Absolute file offset for a (possibly wrapped) block number.
        private var wrapCount = 0
        private var lastRawBlock: UInt16 = 0
        private func sendOffset(for block: UInt16) -> Int {
            if block < lastRawBlock && lastRawBlock &- block > 0x8000 {
                wrapCount += 1
            }
            lastRawBlock = block
            let absolute = wrapCount * 65536 + Int(block)
            return (absolute - 1) * blockSize
        }

        // MARK: Write path (device sends a backup)

        private func handleData(_ packet: Data) {
            guard isWrite, let handle = writeHandle else { receiveNext(); return }
            // Same 4-byte minimum as handleAck — a short DATA must not trap.
            guard packet.count >= 4 else { receiveNext(); return }
            let block = UInt16(packet[packet.startIndex + 2]) << 8 | UInt16(packet[packet.startIndex + 3])
            let payload = packet.dropFirst(4)
            if block == currentBlock &+ 1 {
                do {
                    try handle.write(contentsOf: payload)
                } catch {
                    finish("write failed: \(error.localizedDescription)", failed: true)
                    return
                }
                writtenBytes += payload.count
                currentBlock = block
                reportProgress(done: writtenBytes, total: expectedTotal ?? 0, isUpload: true)
            }
            sendAck(block)
            if payload.count < blockSize {
                try? handle.close()
                writeHandle = nil
                reportDone(done: writtenBytes, isUpload: true)
                finish("received \(ByteFormat.string(Int64(writtenBytes)))")
                return
            }
            receiveNext()
        }

        private func sendAck(_ block: UInt16) {
            let packet = Data([0, 4, UInt8(block >> 8), UInt8(block & 0xFF)])
            lastPacket = packet
            send(packet)
            scheduleRetransmit()
        }

        // MARK: Plumbing

        private func send(_ packet: Data) {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }

        private func scheduleRetransmit() {
            generation += 1
            let expected = generation
            server.serverQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.finished, self.generation == expected else { return }
                self.retries += 1
                if self.retries > 5 {
                    self.finish("timed out", failed: true)
                } else {
                    self.send(self.lastPacket)
                    self.scheduleRetransmit()
                }
            }
        }

        private func sendError(_ code: UInt16, _ message: String) {
            var packet = Data([0, 5, UInt8(code >> 8), UInt8(code & 0xFF)])
            packet.append(contentsOf: message.utf8)
            packet.append(0)
            send(packet)
            server.log(peer: peer, isWrite: isWrite, filename: filename.isEmpty ? "?" : filename,
                       detail: message, failed: true)
            finish(nil)
        }

        private func finish(_ detail: String?, failed: Bool = false) {
            guard !finished else { return }
            finished = true
            generation += 1
            try? readHandle?.close()
            readHandle = nil
            try? writeHandle?.close()
            writeHandle = nil
            if let detail {
                server.log(peer: peer, isWrite: isWrite, filename: filename,
                           detail: detail, failed: failed)
            }
            server.onProgress(nil)      // clear the live bar
            connection.cancel()
            server.sessionEnded(self)
        }
    }
}
