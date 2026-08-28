import CLibSSH
import Foundation

/// Serves one client's SFTP requests against a rooted folder. Runs entirely
/// on its connection's worker thread (see SFTPServerListener). Implements the
/// subset a network device needs: realpath, stat, opendir/readdir, and
/// open/read/write/close — enough to list, pull firmware, and (when writes
/// are allowed) receive a config backup.
nonisolated final class SFTPRequestHandler {
    private let sftp: sftp_session
    private let root: URL
    /// Closure, not a snapshot — the "Allow writes" toggle must apply to
    /// connections that are already open.
    private let allowWrites: @Sendable () -> Bool
    private let peer: String
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let onProgress: ServeProgress
    /// Raw pointers of handles currently held by libssh, so a client that
    /// drops the connection without SSH_FXP_CLOSE doesn't leak the retained
    /// OpenHandle (and its open fd) — see `loop()`.
    private var liveHandles: Set<UnsafeMutableRawPointer> = []

    /// Per-open state, kept alive via Unmanaged while libssh holds the handle.
    private final class OpenHandle {
        enum Kind {
            case directory(entries: [URL], index: Int)
            case file(FileHandle, isWrite: Bool)
        }
        var kind: Kind
        let name: String
        // Live-progress bookkeeping for the file kind.
        var bytes: Int64 = 0
        var total: Int64 = 0
        var lastReported: Int64 = 0
        init(kind: Kind, name: String) { self.kind = kind; self.name = name }
    }

    init(sftp: sftp_session, root: URL, allowWrites: @escaping @Sendable () -> Bool,
         peer: String, onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.sftp = sftp
        self.root = root.standardizedFileURL
        self.allowWrites = allowWrites
        self.peer = peer
        self.onLog = onLog
        self.onProgress = onProgress
    }

    /// Emit at most every 128 KB (and at completion) so a big pull over SFTP
    /// doesn't flood the main actor. `isUpload` = device is writing to us.
    private func reportProgress(_ box: OpenHandle, isUpload: Bool) {
        if box.bytes - box.lastReported >= 128 * 1024 || (box.total > 0 && box.bytes >= box.total) {
            box.lastReported = box.bytes
            onProgress(ServeTransfer(peer: peer, name: box.name, isUpload: isUpload,
                                     done: box.bytes, total: box.total))
        }
    }

    func loop() {
        while let message = sftp_get_client_message(sftp) {
            handle(message)
            sftp_client_message_free(message)
        }
        // The client is gone (clean or not). Release every handle it never
        // closed — each one holds a +1 OpenHandle and an open fd; a flaky
        // device retrying pulls used to leak one fd per attempt. A file handle
        // still open here is an INTERRUPTED transfer — fail its own bar
        // (id-scoped); a cleanly-closed transfer already emitted .done and left
        // liveHandles, so we never touch an unrelated peer's live bar.
        for raw in liveHandles {
            let box = Unmanaged<OpenHandle>.fromOpaque(raw).takeRetainedValue()
            if case .file(let file, let isWrite) = box.kind {
                try? file.close()
                onProgress(ServeTransfer(peer: peer, name: box.name, isUpload: isWrite,
                                         done: box.bytes, total: max(box.total, box.bytes),
                                         state: .failed))
            }
            sftp_handle_remove(sftp, raw)
        }
        liveHandles.removeAll()
    }

    // MARK: - Dispatch

    private func handle(_ message: sftp_client_message) {
        let type = sftp_client_message_get_type(message)
        switch Int32(type) {
        case SSH_FXP_REALPATH: replyRealpath(message)
        case SSH_FXP_STAT, SSH_FXP_LSTAT: replyStat(message)
        case SSH_FXP_FSTAT: replyFStat(message)
        case SSH_FXP_OPENDIR: openDir(message)
        case SSH_FXP_READDIR: readDir(message)
        case SSH_FXP_OPEN: openFile(message)
        case SSH_FXP_READ: readFile(message)
        case SSH_FXP_WRITE: writeFile(message)
        case SSH_FXP_CLOSE: closeHandle(message)
        case SSH_FXP_SETSTAT, SSH_FXP_FSETSTAT:
            _ = sftp_reply_status(message, UInt32(SSH_FX_OK), nil)  // accept, ignore
        case SSH_FXP_MKDIR, SSH_FXP_REMOVE, SSH_FXP_RMDIR, SSH_FXP_RENAME:
            _ = sftp_reply_status(message, UInt32(SSH_FX_OP_UNSUPPORTED), "not supported")
        default:
            _ = sftp_reply_status(message, UInt32(SSH_FX_OP_UNSUPPORTED), "not supported")
        }
    }

    // MARK: - Path safety

    /// Resolves an SFTP path (client-absolute, rooted at the served folder)
    /// to a real URL, refusing anything that escapes the root.
    private func resolve(_ sftpPath: String) -> URL? {
        var path = sftpPath
        if path.isEmpty || path == "." { path = "/" }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if candidate.path == root.path || candidate.path.hasPrefix(rootPath) {
            return candidate
        }
        return nil
    }

    /// Client-facing absolute path for a real URL under the root.
    private func virtualPath(for url: URL) -> String {
        let rel = url.path.dropFirst(root.path.count)
        let s = String(rel)
        return s.isEmpty ? "/" : (s.hasPrefix("/") ? s : "/" + s)
    }

    // MARK: - Handlers

    private func replyRealpath(_ message: sftp_client_message) {
        let requested = String(cString: sftp_client_message_get_filename(message))
        guard let url = resolve(requested) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_NO_SUCH_FILE), "no such path")
            return
        }
        let vpath = virtualPath(for: url)
        withAttributes(for: url, fallbackName: vpath) { attr in
            _ = vpath.withCString { sftp_reply_name(message, $0, attr) }
        }
    }

    private func replyStat(_ message: sftp_client_message) {
        let requested = String(cString: sftp_client_message_get_filename(message))
        guard let url = resolve(requested),
              FileManager.default.fileExists(atPath: url.path) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_NO_SUCH_FILE), "no such file")
            return
        }
        withAttributes(for: url, fallbackName: url.lastPathComponent) { attr in
            _ = sftp_reply_attr(message, attr)
        }
    }

    private func replyFStat(_ message: sftp_client_message) {
        guard let box = handleBox(message.pointee.handle) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "bad handle")
            return
        }
        let url = root.appendingPathComponent(box.name)
        withAttributes(for: url, fallbackName: box.name) { attr in
            _ = sftp_reply_attr(message, attr)
        }
    }

    private func openDir(_ message: sftp_client_message) {
        let requested = String(cString: sftp_client_message_get_filename(message))
        guard let url = resolve(requested) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_NO_SUCH_FILE), "no such directory")
            return
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let box = OpenHandle(kind: .directory(entries: entries.sorted { $0.lastPathComponent < $1.lastPathComponent }, index: 0),
                             name: virtualPath(for: url))
        reply(handleFor: box, to: message)
    }

    private func readDir(_ message: sftp_client_message) {
        guard let box = handleBox(message.pointee.handle),
              case .directory(let entries, let index) = box.kind else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "bad handle")
            return
        }
        if index >= entries.count {
            _ = sftp_reply_status(message, UInt32(SSH_FX_EOF), nil)
            return
        }
        let end = min(index + 50, entries.count)
        for i in index..<end {
            let url = entries[i]
            let name = url.lastPathComponent
            withAttributes(for: url, fallbackName: name) { attr in
                let longname = Self.longname(for: url, name: name)
                _ = name.withCString { namePtr in
                    longname.withCString { longPtr in
                        sftp_reply_names_add(message, namePtr, longPtr, attr)
                    }
                }
            }
        }
        box.kind = .directory(entries: entries, index: end)
        _ = sftp_reply_names(message)
    }

    private func openFile(_ message: sftp_client_message) {
        let requested = String(cString: sftp_client_message_get_filename(message))
        let flags = sftp_client_message_get_flags(message)
        let wantsWrite = flags & UInt32(SSH_FXF_WRITE) != 0
        guard let url = resolve(requested) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_NO_SUCH_FILE), "no such file")
            return
        }
        if wantsWrite {
            guard allowWrites() else {
                _ = sftp_reply_status(message, UInt32(SSH_FX_PERMISSION_DENIED), "writes are disabled")
                log(isWrite: true, name: virtualPath(for: url), detail: "rejected (writes off)", failed: true)
                return
            }
            if flags & UInt32(SSH_FXF_CREAT) != 0 || !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "cannot open for writing")
                return
            }
            if flags & UInt32(SSH_FXF_TRUNC) != 0 { try? handle.truncate(atOffset: 0) }
            let box = OpenHandle(kind: .file(handle, isWrite: true), name: virtualPath(for: url))
            log(isWrite: true, name: box.name, detail: "receiving", failed: false)
            reply(handleFor: box, to: message)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                _ = sftp_reply_status(message, UInt32(SSH_FX_NO_SUCH_FILE), "no such file")
                return
            }
            let box = OpenHandle(kind: .file(handle, isWrite: false), name: virtualPath(for: url))
            let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            box.total = Int64(sz ?? 0)
            log(isWrite: false, name: box.name, detail: "serving", failed: false)
            reply(handleFor: box, to: message)
        }
    }

    private func readFile(_ message: sftp_client_message) {
        guard let box = handleBox(message.pointee.handle),
              case .file(let handle, false) = box.kind else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "bad handle")
            return
        }
        let offset = message.pointee.offset
        let length = Int(message.pointee.len)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: length) ?? Data()
            if data.isEmpty {
                _ = sftp_reply_status(message, UInt32(SSH_FX_EOF), nil)
            } else {
                _ = data.withUnsafeBytes { raw in
                    sftp_reply_data(message, raw.baseAddress, Int32(data.count))
                }
                box.bytes = max(box.bytes, Int64(offset) + Int64(data.count))
                reportProgress(box, isUpload: false)
            }
        } catch {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "read failed")
        }
    }

    private func writeFile(_ message: sftp_client_message) {
        guard let box = handleBox(message.pointee.handle),
              case .file(let handle, true) = box.kind else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "bad handle")
            return
        }
        let offset = message.pointee.offset
        guard let dataString = message.pointee.data else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "no data")
            return
        }
        let length = Int(ssh_string_len(dataString))
        // A zero-length write is protocol-legal; ssh_string_data returns NULL
        // for it, and the old force-unwrap crashed.
        guard length > 0, let bytes = ssh_string_data(dataString) else {
            _ = sftp_reply_status(message, UInt32(SSH_FX_OK), nil)
            return
        }
        let data = Data(bytes: bytes, count: length)
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            _ = sftp_reply_status(message, UInt32(SSH_FX_OK), nil)
            box.bytes = max(box.bytes, Int64(offset) + Int64(length))
            reportProgress(box, isUpload: true)
        } catch {
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "write failed")
        }
    }

    private func closeHandle(_ message: sftp_client_message) {
        if let handle = message.pointee.handle, let raw = sftp_handle(sftp, handle) {
            let box = Unmanaged<OpenHandle>.fromOpaque(raw).takeRetainedValue()
            liveHandles.remove(raw)
            if case .file(let file, let isWrite) = box.kind {
                try? file.close()
                if isWrite { log(isWrite: true, name: box.name, detail: "received", failed: false) }
                else { log(isWrite: false, name: box.name, detail: "sent", failed: false) }
                // Keep the completed transfer as a history row (loop()'s
                // finalizing onProgress(nil) leaves a .done in place).
                onProgress(ServeTransfer(peer: peer, name: box.name, isUpload: isWrite,
                                         done: box.bytes, total: max(box.total, box.bytes),
                                         state: .done))
            }
            sftp_handle_remove(sftp, raw)
        }
        _ = sftp_reply_status(message, UInt32(SSH_FX_OK), nil)
    }

    // MARK: - Handle plumbing

    private func reply(handleFor box: OpenHandle, to message: sftp_client_message) {
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard let handleString = sftp_handle_alloc(sftp, raw) else {
            Unmanaged<OpenHandle>.fromOpaque(raw).release()
            _ = sftp_reply_status(message, UInt32(SSH_FX_FAILURE), "out of handles")
            return
        }
        liveHandles.insert(raw)
        _ = sftp_reply_handle(message, handleString)
        ssh_string_free(handleString)
    }

    private func handleBox(_ handle: ssh_string?) -> OpenHandle? {
        guard let handle, let raw = sftp_handle(sftp, handle) else { return nil }
        return Unmanaged<OpenHandle>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Builds an sftp_attributes for `url`, calls `body`, then frees it.
    private func withAttributes(for url: URL, fallbackName: String,
                                _ body: (sftp_attributes) -> Void) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = values?.isDirectory ?? false
        let attr = UnsafeMutablePointer<sftp_attributes_struct>.allocate(capacity: 1)
        attr.initialize(to: sftp_attributes_struct())
        defer { attr.deinitialize(count: 1); attr.deallocate() }
        attr.pointee.flags = UInt32(SSH_FILEXFER_ATTR_SIZE
            | SSH_FILEXFER_ATTR_PERMISSIONS | SSH_FILEXFER_ATTR_ACMODTIME)
        attr.pointee.size = UInt64(values?.fileSize ?? 0)
        attr.pointee.type = isDir ? 2 : 1  // SSH_FILEXFER_TYPE_DIRECTORY / REGULAR
        attr.pointee.permissions = isDir ? 0o040755 : 0o100644
        let mtime = UInt32((values?.contentModificationDate ?? Date()).timeIntervalSince1970)
        attr.pointee.mtime = mtime
        attr.pointee.atime = mtime
        body(attr)
    }

    private static func longname(for url: URL, name: String) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDir = values?.isDirectory ?? false
        let perms = isDir ? "drwxr-xr-x" : "-rw-r--r--"
        let size = values?.fileSize ?? 0
        return String(format: "%@ 1 sheepdrop sheepdrop %9d Jan 1 00:00 %@", perms, size, name)
    }

    private func log(isWrite: Bool, name: String, detail: String, failed: Bool) {
        onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: isWrite,
                           filename: name, detail: "SFTP · " + detail, failed: failed))
    }
}
