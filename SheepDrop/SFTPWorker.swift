import CLibSSH
import Foundation

struct SFTPConfig: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    /// Overrides ~/.ssh/known_hosts — used by the test harness so throwaway
    /// server keys never land in the user's real file. nil = system default.
    var knownHostsPath: String?
}

struct SFTPError: Error, Sendable {
    var message: String
    /// True when the failure was an authentication rejection — the UI
    /// re-prompts for the password instead of showing a dead error.
    var isAuthFailure = false
}

/// One libssh session + SFTP channel on its own serial queue. libssh
/// sessions are not thread-safe, so EVERY ssh_*/sftp_* call happens on that
/// queue — `session`/`sftp` are queue-confined (that is the whole
/// @unchecked Sendable contract here; never touch them off-queue). Modeled
/// on SheepTerm's SSHWorker: same legacy-cipher fallback for old Cisco/Aruba
/// gear, same fail-closed known_hosts policy.
nonisolated final class SFTPWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sheepdrop.sftp.session")

    // Queue-confined — see class comment.
    private var session: ssh_session?
    private var sftp: sftp_session?

    private static let legacyKex = "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1"
    private static let legacyCiphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc"
    private static let legacyHostKeys = "ssh-ed25519,ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa,ssh-dss"
    private static let legacyMacs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1,hmac-md5"

    deinit {
        // The owner is expected to call disconnect(); this is the backstop.
        let session = self.session
        let sftp = self.sftp
        if session != nil || sftp != nil {
            queue.async {
                if let sftp { sftp_free(sftp) }
                if let session {
                    ssh_disconnect(session)
                    ssh_free(session)
                }
            }
        }
    }

    // MARK: - Async surface (call from anywhere)

    /// Connects and opens the SFTP channel. Returns a human-readable notice
    /// (first-connection host-key message) or nil.
    func connect(_ config: SFTPConfig) async throws -> String? {
        try await onQueue { try $0.doConnect(config, openSFTP: true) }
    }

    /// Connect + authenticate only — for SCP, which runs over exec channels
    /// created per transfer instead of a long-lived subsystem.
    func connectSSHOnly(_ config: SFTPConfig) async throws -> String? {
        try await onQueue { try $0.doConnect(config, openSFTP: false) }
    }

    /// SCP connect, WinSCP-style: authenticate, then *try* to open the SFTP
    /// subsystem for browsing. If the device serves it, the session becomes
    /// fully browsable (list/enter/download/upload all run over SFTP, same as an
    /// SFTP host); if the device refuses it (e.g. some Aruba CX builds), we stay
    /// connected and fall back to blind SCP put/get. `browsable` says which.
    func connectSCP(_ config: SFTPConfig) async throws -> (notice: String?, browsable: Bool) {
        try await onQueue {
            let notice = try $0.doConnect(config, openSFTP: true, sftpOptional: true)
            return (notice, $0.sftp != nil)
        }
    }

    func scpUpload(localURL: URL, to remotePath: String,
                   progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { try $0.doSCPUpload(localURL, remotePath, progress) }
    }

    func scpDownload(remotePath: String, to localURL: URL,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { try $0.doSCPDownload(remotePath, localURL, progress) }
    }

    func disconnect() {
        queue.async { [self] in
            if let sftp { sftp_free(sftp) }
            sftp = nil
            if let session {
                ssh_disconnect(session)
                ssh_free(session)
            }
            session = nil
        }
    }

    /// Server-side canonical path of the login directory.
    func homeDirectory() async throws -> String {
        try await onQueue { try $0.doCanonicalize(".") }
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] {
        try await onQueue { try $0.doList(path) }
    }

    func download(remotePath: String, to localURL: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { try $0.doDownload(remotePath, localURL, progress) }
    }

    func upload(localURL: URL, to remotePath: String,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await onQueue { try $0.doUpload(localURL, remotePath, progress) }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (SFTPWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    // MARK: - Queue-side implementation

    private func doConnect(_ config: SFTPConfig, openSFTP: Bool, sftpOptional: Bool = false) throws -> String? {
        guard session == nil else { return nil }
        var notice: String?

        // Modern algorithms first; retry with the legacy set for old gear.
        var candidate = try makeConnectedSession(config, legacy: false, error: &notice)
        if candidate == nil {
            candidate = try makeConnectedSession(config, legacy: true, error: &notice)
        }
        guard let connected = candidate else {
            throw SFTPError(message: notice ?? "connection failed")
        }

        do {
            let hostKeyNotice = try verifyHostKey(connected)
            try authenticate(connected, config)
            if openSFTP {
                let refusal = "the device refused the SFTP subsystem — many network devices (e.g. this CX build) only serve SCP. Add this host again with protocol SCP."
                let channel = sftp_new(connected)
                if let channel, sftp_init(channel) == 0 {
                    sftp = channel
                } else {
                    if let channel { sftp_free(channel) }
                    // sftpOptional (SCP-hybrid): a refused subsystem is fine —
                    // the caller falls back to blind SCP. Otherwise it's fatal.
                    if !sftpOptional {
                        throw SFTPError(message: "\(refusal) [\(Self.errorString(connected))]")
                    }
                }
            }
            session = connected
            return hostKeyNotice
        } catch {
            ssh_disconnect(connected)
            ssh_free(connected)
            throw error
        }
    }

    // MARK: - SCP (exec-channel transfers over the authenticated session)

    private func doSCPUpload(_ localURL: URL, _ remotePath: String,
                             _ progress: @Sendable (Int64, Int64) -> Void) throws {
        guard let session else { throw SFTPError(message: "not connected") }
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError(message: "cannot read \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }
        let total = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        // "flash:/img.swi" → location "flash:", name "img.swi"; a path with
        // no slash (CX "primary") is used as the location and keeps the
        // local file name.
        let (location, name) = Self.splitRemotePath(remotePath, fallbackName: localURL.lastPathComponent)

        guard let scp = ssh_scp_new(session, Int32(SSH_SCP_WRITE), location) else {
            throw SFTPError(message: "scp channel failed: \(Self.errorString(session))")
        }
        defer { ssh_scp_free(scp) }
        guard ssh_scp_init(scp) == 0 else {
            throw SFTPError(message: "scp refused for “\(location)”: \(Self.errorString(session))")
        }
        defer { ssh_scp_close(scp) }
        guard ssh_scp_push_file64(scp, name, UInt64(total), 0o644) == 0 else {
            throw SFTPError(message: "scp push refused for “\(name)”: \(Self.errorString(session))")
        }
        var done: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let result = chunk.withUnsafeBytes { raw in
                ssh_scp_write(scp, raw.baseAddress, raw.count)
            }
            guard result == 0 else {
                throw SFTPError(message: "scp write failed at \(done) bytes: \(Self.errorString(session))")
            }
            done += Int64(chunk.count)
            progress(done, total)
        }
    }

    private func doSCPDownload(_ remotePath: String, _ localURL: URL,
                               _ progress: @Sendable (Int64, Int64) -> Void) throws {
        guard let session else { throw SFTPError(message: "not connected") }
        guard let scp = ssh_scp_new(session, Int32(SSH_SCP_READ), remotePath) else {
            throw SFTPError(message: "scp channel failed: \(Self.errorString(session))")
        }
        defer { ssh_scp_free(scp) }
        guard ssh_scp_init(scp) == 0 else {
            throw SFTPError(message: "scp refused for “\(remotePath)”: \(Self.errorString(session))")
        }
        defer { ssh_scp_close(scp) }

        guard ssh_scp_pull_request(scp) == SSH_SCP_REQUEST_NEWFILE.rawValue else {
            throw SFTPError(message: "device did not offer a file for “\(remotePath)”: \(Self.errorString(session))")
        }
        let total = Int64(bitPattern: ssh_scp_request_get_size64(scp))
        guard ssh_scp_accept_request(scp) == 0 else {
            throw SFTPError(message: "scp accept failed: \(Self.errorString(session))")
        }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError(message: "cannot write \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var done: Int64 = 0
        while done < total {
            let count = buffer.withUnsafeMutableBytes { raw in
                ssh_scp_read(scp, raw.baseAddress, min(raw.count, Int(total - done)))
            }
            guard count > 0 else {
                throw SFTPError(message: "scp read failed at \(done) bytes: \(Self.errorString(session))")
            }
            try handle.write(contentsOf: Data(bytes: buffer, count: Int(count)))
            done += Int64(count)
            progress(done, total)
        }
    }

    /// "flash:/img.swi" → ("flash:", "img.swi"); "backups/run.cfg" →
    /// ("backups", "run.cfg"); "primary" (no slash) → ("primary", local name).
    static func splitRemotePath(_ remotePath: String, fallbackName: String) -> (location: String, name: String) {
        guard let slash = remotePath.lastIndex(of: "/") else {
            return (remotePath, fallbackName)
        }
        let name = String(remotePath[remotePath.index(after: slash)...])
        let location = String(remotePath[..<slash])
        return (location.isEmpty ? "/" : location, name.isEmpty ? fallbackName : name)
    }

    /// Returns nil (with `error` set) when the TCP/SSH handshake fails so the
    /// caller can retry with the legacy algorithm set.
    private func makeConnectedSession(_ config: SFTPConfig, legacy: Bool,
                                      error: inout String?) throws -> ssh_session? {
        guard let session = ssh_new() else {
            throw SFTPError(message: "ssh_new failed")
        }
        setOption(session, SSH_OPTIONS_HOST, config.host)
        guard let portValue = UInt32(exactly: config.port), (1...65535).contains(config.port) else {
            ssh_free(session)
            throw SFTPError(message: "invalid port \(config.port)")
        }
        var port = portValue
        _ = ssh_options_set(session, SSH_OPTIONS_PORT, &port)
        if !config.username.isEmpty {
            setOption(session, SSH_OPTIONS_USER, config.username)
        }
        var timeout = 15
        _ = ssh_options_set(session, SSH_OPTIONS_TIMEOUT, &timeout)
        if let knownHosts = config.knownHostsPath {
            setOption(session, SSH_OPTIONS_KNOWNHOSTS, knownHosts)
        }

        if legacy {
            setOption(session, SSH_OPTIONS_KEY_EXCHANGE, Self.legacyKex)
            setOption(session, SSH_OPTIONS_CIPHERS_C_S, Self.legacyCiphers)
            setOption(session, SSH_OPTIONS_CIPHERS_S_C, Self.legacyCiphers)
            setOption(session, SSH_OPTIONS_HOSTKEYS, Self.legacyHostKeys)
            setOption(session, SSH_OPTIONS_HMAC_C_S, Self.legacyMacs)
            setOption(session, SSH_OPTIONS_HMAC_S_C, Self.legacyMacs)
            setOption(session, SSH_OPTIONS_PUBLICKEY_ACCEPTED_TYPES, Self.legacyHostKeys)
        }

        guard ssh_connect(session) == 0 else {
            error = Self.errorString(session)
            ssh_free(session)
            return nil
        }
        return session
    }

    /// Fail closed, exactly like SheepTerm: an unreadable known_hosts or a
    /// changed key refuses the connection; unknown keys are pinned.
    private func verifyHostKey(_ session: ssh_session) throws -> String? {
        switch ssh_session_is_known_server(session) {
        case SSH_KNOWN_HOSTS_OK:
            return nil
        case SSH_KNOWN_HOSTS_ERROR:
            throw SFTPError(message: "cannot read ~/.ssh/known_hosts — refusing to trust any host key. Fix or remove the file, then reconnect.")
        case SSH_KNOWN_HOSTS_CHANGED:
            throw SFTPError(message: "HOST KEY CHANGED — possible man-in-the-middle. If the device was reinstalled, remove its entry from ~/.ssh/known_hosts and reconnect.")
        case SSH_KNOWN_HOSTS_OTHER:
            let saved = ssh_session_update_known_hosts(session) == 0
            return saved ? "host key type changed for this server; new key saved"
                : "host key could NOT be saved to known_hosts: \(Self.errorString(session))"
        default: // NOT_FOUND / UNKNOWN — first connection
            let saved = ssh_session_update_known_hosts(session) == 0
            return saved ? "first connection — host key saved to known_hosts"
                : "host key could NOT be saved to known_hosts: \(Self.errorString(session))"
        }
    }

    private func authenticate(_ session: ssh_session, _ config: SFTPConfig) throws {
        let AUTH_SUCCESS: Int32 = 0
        let AUTH_INFO: Int32 = 3

        if ssh_userauth_none(session, nil) == AUTH_SUCCESS { return }
        // What the server actually accepts (valid after the none attempt).
        // 0 = server didn't say; assume everything.
        var methods = UInt32(bitPattern: ssh_userauth_list(session, nil))
        if methods == 0 {
            methods = SSH_AUTH_METHOD_PASSWORD | SSH_AUTH_METHOD_INTERACTIVE | SSH_AUTH_METHOD_PUBLICKEY
        }
        var failures: [String] = []

        // Password-carrying methods FIRST. Offering agent keys before them
        // burns a network device's MaxAuthTries — an Aruba CX would then
        // reject the correct password because the attempt budget was spent
        // on keys the switch never wanted.
        if let password = config.password, !password.isEmpty {
            if methods & SSH_AUTH_METHOD_PASSWORD != 0 {
                if password.withCString({ ssh_userauth_password(session, nil, $0) }) == AUTH_SUCCESS {
                    return
                }
                failures.append("password rejected")
            }
            if methods & SSH_AUTH_METHOD_INTERACTIVE != 0 {
                // AOS-CX and TACACS setups often accept ONLY this. Non-echo
                // prompts get the password; echo prompts asking for a
                // user/login name get the username.
                var interactive = ssh_userauth_kbdint(session, nil, nil)
                answering: while interactive == AUTH_INFO {
                    let prompts = ssh_userauth_kbdint_getnprompts(session)
                    guard prompts >= 0 else { break }
                    for index in 0..<prompts {
                        var echo: CChar = 0
                        guard let rawPrompt = ssh_userauth_kbdint_getprompt(session, UInt32(index), &echo) else {
                            failures.append("keyboard-interactive prompt error")
                            break answering
                        }
                        let promptText = String(cString: rawPrompt)
                        let answer: String
                        if echo == 0 {
                            answer = password
                        } else if promptText.lowercased().contains("user")
                            || promptText.lowercased().contains("login")
                            || promptText.lowercased().contains("name") {
                            answer = config.username
                        } else {
                            failures.append("keyboard-interactive asked “\(promptText)” — no way to answer it yet")
                            break answering
                        }
                        guard answer.withCString({ ssh_userauth_kbdint_setanswer(session, UInt32(index), $0) }) >= 0 else {
                            failures.append("keyboard-interactive answer error: \(Self.errorString(session))")
                            break answering
                        }
                    }
                    interactive = ssh_userauth_kbdint(session, nil, nil)
                }
                if interactive == AUTH_SUCCESS { return }
                if failures.last?.hasPrefix("keyboard-interactive") != true {
                    failures.append("keyboard-interactive rejected")
                }
            }
        }
        if methods & SSH_AUTH_METHOD_PUBLICKEY != 0,
           ssh_userauth_publickey_auto(session, nil, nil) == AUTH_SUCCESS {
            return
        }

        guard let password = config.password, !password.isEmpty else {
            throw SFTPError(message: "password required", isAuthFailure: true)
        }
        var offered: [String] = []
        if methods & SSH_AUTH_METHOD_PASSWORD != 0 { offered.append("password") }
        if methods & SSH_AUTH_METHOD_INTERACTIVE != 0 { offered.append("keyboard-interactive") }
        if methods & SSH_AUTH_METHOD_PUBLICKEY != 0 { offered.append("publickey") }
        let detail = failures.isEmpty ? "" : " (\(failures.joined(separator: "; ")))"
        throw SFTPError(
            message: "authentication failed for \(config.username)@\(config.host) — server accepts: \(offered.joined(separator: ", "))\(detail)",
            isAuthFailure: true)
    }

    private func doCanonicalize(_ path: String) throws -> String {
        guard let sftp else { throw SFTPError(message: "not connected") }
        guard let raw = sftp_canonicalize_path(sftp, path) else {
            throw SFTPError(message: "canonicalize failed: \(currentError())")
        }
        defer { ssh_string_free_char(raw) }
        return String(cString: raw)
    }

    private func doList(_ path: String) throws -> [FileEntry] {
        guard let sftp else { throw SFTPError(message: "not connected") }
        guard let dir = sftp_opendir(sftp, path) else {
            throw SFTPError(message: "cannot open \(path): \(currentError())")
        }
        defer { sftp_closedir(dir) }
        var entries: [FileEntry] = []
        while let attrs = sftp_readdir(sftp, dir) {
            defer { sftp_attributes_free(attrs) }
            let record = attrs.pointee
            guard let namePointer = record.name else { continue }
            let name = String(cString: namePointer)
            if name == "." || name == ".." { continue }
            if name.hasPrefix(".") { continue }
            // A directory is one the server flags as a dir by TYPE **or** by the
            // POSIX S_IFDIR bit. Many SFTP servers (network gear especially)
            // leave `type` as UNKNOWN and only set permissions — relying on
            // `type` alone made every folder look like a file, so double-click
            // (guarded by isDirectory) did nothing and browsing was stuck at the
            // login directory.
            let hasPerms = record.flags & UInt32(SSH_FILEXFER_ATTR_PERMISSIONS) != 0
            let isDirectory = record.type == UInt8(SSH_FILEXFER_TYPE_DIRECTORY)
                || (hasPerms && (record.permissions & UInt32(S_IFMT)) == UInt32(S_IFDIR))
            entries.append(FileEntry(
                name: name,
                isDirectory: isDirectory,
                size: Int64(bitPattern: record.size),
                modified: record.mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(record.mtime)),
                permissions: Self.permissionString(record.permissions, isDirectory: isDirectory)
            ))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func doDownload(_ remotePath: String, _ localURL: URL,
                            _ progress: @Sendable (Int64, Int64) -> Void) throws {
        guard let sftp else { throw SFTPError(message: "not connected") }
        let total = (try? doStatSize(remotePath)) ?? 0
        guard let file = sftp_open(sftp, remotePath, O_RDONLY, 0) else {
            throw SFTPError(message: "cannot open \(remotePath): \(currentError())")
        }
        defer { sftp_close(file) }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError(message: "cannot write \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var done: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                sftp_read(file, raw.baseAddress, raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                throw SFTPError(message: "read failed at \(done) bytes: \(currentError())")
            }
            try handle.write(contentsOf: Data(bytes: buffer, count: count))
            done += Int64(count)
            progress(done, total)
        }
    }

    private func doUpload(_ localURL: URL, _ remotePath: String,
                          _ progress: @Sendable (Int64, Int64) -> Void) throws {
        guard let sftp else { throw SFTPError(message: "not connected") }
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError(message: "cannot read \(localURL.lastPathComponent)")
        }
        defer { try? handle.close() }
        let total = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        guard let file = sftp_open(sftp, remotePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644) else {
            throw SFTPError(message: "cannot create \(remotePath): \(currentError())")
        }
        defer { sftp_close(file) }

        var done: Int64 = 0
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
            // sftp_write caps each request at one SFTP packet (~32 KB) and
            // returns how much it accepted — loop until the chunk is gone.
            try chunk.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = sftp_write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard written > 0 else {
                        throw SFTPError(message: "write failed at \(done + Int64(offset)) bytes: \(currentError())")
                    }
                    offset += written
                }
            }
            done += Int64(chunk.count)
            progress(done, total)
        }
    }

    private func doStatSize(_ path: String) throws -> Int64 {
        guard let sftp, let attrs = sftp_stat(sftp, path) else {
            throw SFTPError(message: "stat failed")
        }
        defer { sftp_attributes_free(attrs) }
        return Int64(bitPattern: attrs.pointee.size)
    }

    /// 0o755 → "drwxr-xr-x", ls style.
    static func permissionString(_ mode: UInt32, isDirectory: Bool) -> String? {
        guard mode != 0 else { return nil }
        var result = isDirectory ? "d" : "-"
        let triads: [(UInt32, UInt32, UInt32)] = [
            (mode & 0o400, mode & 0o200, mode & 0o100),
            (mode & 0o040, mode & 0o020, mode & 0o010),
            (mode & 0o004, mode & 0o002, mode & 0o001),
        ]
        for (read, write, execute) in triads {
            result += read != 0 ? "r" : "-"
            result += write != 0 ? "w" : "-"
            result += execute != 0 ? "x" : "-"
        }
        return result
    }

    private func currentError() -> String {
        guard let session else { return "unknown error" }
        return Self.errorString(session)
    }

    private func setOption(_ session: ssh_session?, _ option: ssh_options_e, _ value: String) {
        value.withCString {
            _ = ssh_options_set(session, option, $0)
        }
    }

    private static func errorString(_ session: ssh_session?) -> String {
        guard let session else { return "unknown error" }
        return String(cString: ssh_get_error(UnsafeMutableRawPointer(session)))
    }
}
