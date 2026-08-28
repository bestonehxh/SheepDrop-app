import CLibSSH
import Foundation

/// Built-in SFTP server: lets a switch/router pull (or push) files over
/// `sftp://user@mac:port/file`, the SSH counterpart of the TFTP server.
///
/// Security: authenticates against an app-defined VIRTUAL user + password
/// (never the macOS account), stored in UserDefaults (user) + Keychain
/// (password). Serves a single root folder (shared with the TFTP server).
/// Path traversal above the root is rejected. Writes require the same
/// "allow writes" switch as TFTP.
///
/// Threading: one accept loop thread; one worker thread per connection. All
/// libssh calls for a given session stay on that session's thread. Log lines
/// hop to the UI via the @Sendable callback.

nonisolated final class SFTPServerListener: @unchecked Sendable {
    struct Config: Sendable {
        var port: UInt16
        var username: String
        var password: String
        var rootPath: String
        var allowWrites: Bool
    }

    private let config: Config
    private let onLog: @Sendable (TFTPLogEntry) -> Void
    private let onProgress: ServeProgress
    private let acceptQueue = DispatchQueue(label: "sheepdrop.sftp.server.accept")
    private let stateLock = NSLock()
    private var bind: OpaquePointer?
    private var running = false
    /// Read per write-op so flipping "Allow writes" applies to a running server.
    private let allowWritesNow: @Sendable () -> Bool

    init(config: Config, allowWrites: (@Sendable () -> Bool)? = nil,
         onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
         onProgress: @escaping ServeProgress = { _ in }) {
        self.config = config
        self.allowWritesNow = allowWrites ?? { config.allowWrites }
        self.onLog = onLog
        self.onProgress = onProgress
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    // MARK: - Algorithm compatibility (modern first, legacy fallback)
    //
    // The server-side mirror of SheepTerm's client policy: offer strong
    // algorithms FIRST so any modern client negotiates them, but also include
    // the legacy KEX/ciphers/MACs/host-key types that old switches (Cisco IOS,
    // older HP/Comware, ArubaOS) need. Modern libssh DISABLES these by default
    // (group1/group14-sha1, aes-cbc, 3des, hmac-sha1/md5, ssh-rsa/SHA-1), so an
    // old switch that supports nothing newer can't connect unless we opt back
    // in. libssh negotiates the client's most-preferred match, and because the
    // strong algorithms lead each list, a modern client is never downgraded —
    // legacy is used only when the client offers nothing better. Same strings
    // (and ordering) as SheepTerm/SSHWorker so the family behaves identically.
    private static let compatKex = "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1"
    private static let compatCiphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc"
    private static let compatMacs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1,hmac-md5"
    // Only the host-key types we actually hold a key for (ed25519 + RSA), modern
    // first. ssh-rsa (SHA-1) is included for switches that lack rsa-sha2.
    private static let compatHostKeyAlgos = "ssh-ed25519,rsa-sha2-512,rsa-sha2-256,ssh-rsa"

    /// Devices that pull over SCP (Aruba `copy scp:`, most switches) hard-code
    /// SSH port 22 with no way to name another — so try 22 first and fall back
    /// to 2222 only if it's taken (e.g. macOS Remote Login owns 22).
    static let fallbackPort: UInt16 = 2222

    /// Ensures a host key exists, binds, and starts accepting. Returns the
    /// bound port. Throws SFTPError on failure.
    func start() async throws -> UInt16 {
        let hostKeyPaths = try Self.ensureHostKeys()
        return try await withCheckedThrowingContinuation { continuation in
            acceptQueue.async { [self] in
                do {
                    let port: UInt16
                    do {
                        port = try bindAndListen(hostKeyPaths: hostKeyPaths, port: config.port)
                    } catch {
                        guard config.port != Self.fallbackPort else { throw error }
                        port = try bindAndListen(hostKeyPaths: hostKeyPaths, port: Self.fallbackPort)
                    }
                    stateLock.lock(); running = true; stateLock.unlock()
                    continuation.resume(returning: port)
                    acceptLoop()    // occupies acceptQueue until stop()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must NOT go through acceptQueue — that serial queue is occupied by the
    /// accept loop for the server's whole life, so an async'd stop block never
    /// ran: the UI said "Off" while the server kept accepting logins, and the
    /// next start() failed on the still-bound port. Instead: flip the flag and
    /// neuter the listening socket from the caller's thread (dup2 /dev/null
    /// over the fd — the blocked ssh_bind_accept fails immediately, and unlike
    /// a bare close() there is no fd-reuse race with ssh_bind_free's own
    /// close). The loop then exits and frees the bind on its own thread.
    func stop() {
        stateLock.lock()
        running = false
        let bind = bind
        stateLock.unlock()
        if let bind {
            let fd = ssh_bind_get_fd(bind)
            if fd >= 0 {
                let devnull = open("/dev/null", O_RDONLY)
                if devnull >= 0 {
                    dup2(devnull, fd)
                    close(devnull)
                }
            }
        }
    }

    // MARK: - Bind

    private func bindAndListen(hostKeyPaths: [String], port bindPort: UInt16) throws -> UInt16 {
        guard let bind = ssh_bind_new() else {
            throw SFTPError(message: "ssh_bind_new failed")
        }
        self.bind = bind
        var port = Int32(bindPort)
        _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_BINDPORT, &port)
        // Offer every host key type. libssh slots each by type (rsa/ed25519), so
        // repeated SSH_BIND_OPTIONS_HOSTKEY calls accumulate rather than replace,
        // and the client picks whichever it supports.
        for keyPath in hostKeyPaths {
            keyPath.withCString { _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_HOSTKEY, $0) }
        }
        // Modern-first, legacy-included algorithm sets (see the compat* strings).
        // Accepted sessions inherit these, so an old switch and a modern client
        // both connect, each getting the strongest it supports.
        Self.compatKex.withCString { _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_KEY_EXCHANGE, $0) }
        Self.compatCiphers.withCString {
            _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_CIPHERS_C_S, $0)
            _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_CIPHERS_S_C, $0)
        }
        Self.compatMacs.withCString {
            _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_HMAC_C_S, $0)
            _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_HMAC_S_C, $0)
        }
        Self.compatHostKeyAlgos.withCString { _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_HOSTKEY_ALGORITHMS, $0) }
        "0.0.0.0".withCString { _ = ssh_bind_options_set(bind, SSH_BIND_OPTIONS_BINDADDR, $0) }

        guard ssh_bind_listen(bind) == SSH_OK else {
            let message = String(cString: ssh_get_error(UnsafeMutableRawPointer(bind)))
            ssh_bind_free(bind)
            self.bind = nil
            throw SFTPError(message: "cannot listen on port \(bindPort): \(message)")
        }
        return bindPort
    }

    private func acceptLoop() {
        while isRunning, let bind {
            guard let session = ssh_new() else { break }
            if ssh_bind_accept(bind, session) != SSH_OK {
                ssh_free(session)
                if !isRunning { break }
                continue
            }
            guard isRunning else { ssh_free(session); break }
            let config = self.config
            let onLog = self.onLog
            let onProgress = self.onProgress
            let allowWrites = self.allowWritesNow
            Thread.detachNewThread {
                Self.serve(session: session, config: config,
                           allowWrites: allowWrites, onLog: onLog, onProgress: onProgress)
            }
        }
        // Cleanup on this thread — the same one every other call on this bind
        // ran on. (stop() already invalidated the socket.)
        stateLock.lock()
        if let bind { ssh_bind_free(bind) }
        bind = nil
        stateLock.unlock()
    }

    // MARK: - Host keys

    /// Returns the paths of every host key the bind should offer. We generate
    /// BOTH an ed25519 key (modern clients) and a 2048-bit RSA key, because
    /// legacy network gear — ArubaOS switches, Cisco IOS, older HP/Comware —
    /// does NOT support ed25519 host keys and offers only `ssh-rsa` /
    /// `rsa-sha2-256/512` (and sometimes ecdsa). With ed25519 alone, an Aruba
    /// `copy scp:` died at key exchange with "no match for method server host
    /// key algo" and the switch just printed "Error downloading file". Offering
    /// an RSA key too gives every client a common algorithm. libssh selects the
    /// key type the client asks for, so modern clients still get ed25519.
    private static func ensureHostKeys() throws -> [String] {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // RSA first so a client that lists ed25519 last (or not at all) still
        // negotiates; libssh matches by the client's preference order regardless.
        let rsa = try ensureKey(type: SSH_KEYTYPE_RSA, bits: 2048,
                                filename: "sftp_server_rsa", in: dir)
        let ed = try ensureKey(type: SSH_KEYTYPE_ED25519, bits: 0,
                               filename: "sftp_server_ed25519", in: dir)
        return [rsa, ed]
    }

    private static func ensureKey(type: ssh_keytypes_e, bits: Int32,
                                  filename: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(filename)
        let path = url.path
        // Reuse only a NON-EMPTY key — a previous failed export could leave a
        // 0-byte file that libssh then rejects as "no usable hostkeys".
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > 0 {
            return path
        }
        try? FileManager.default.removeItem(at: url)

        var key: ssh_key?
        guard ssh_pki_generate(type, bits, &key) == SSH_OK, let key else {
            throw SFTPError(message: "could not generate an SFTP host key")
        }
        defer { ssh_key_free(key) }
        // passphrase = nil (an empty string is not the same as "no passphrase"
        // and made export write nothing).
        guard path.withCString({ ssh_pki_export_privkey_file(key, nil, nil, nil, $0) }) == SSH_OK,
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
              size > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw SFTPError(message: "could not save the SFTP host key")
        }
        return path
    }

    // MARK: - One connection (runs on its own thread)

    private static func serve(session: ssh_session,
                              config: Config,
                              allowWrites: @escaping @Sendable () -> Bool,
                              onLog: @escaping @Sendable (TFTPLogEntry) -> Void,
                              onProgress: @escaping ServeProgress) {
        defer {
            ssh_disconnect(session)
            ssh_free(session)
        }
        let peer = peerString(session)
        guard ssh_handle_key_exchange(session) == SSH_OK else {
            // Surface KEX failures to the Serve log — an ed25519-only host key
            // against a legacy switch fails here with "no match for method
            // server host key algo", which was otherwise invisible. libssh's
            // initial "disconnected" probe is common and not worth logging.
            let err = String(cString: ssh_get_error(UnsafeMutableRawPointer(session)))
            if !err.contains("disconnected") {
                onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: false,
                                   filename: "(handshake)", detail: "SSH key exchange failed: \(err)", failed: true))
            }
            return
        }

        guard authenticate(session, config: config) else {
            onLog(TFTPLogEntry(time: Date(), peer: peer, isWrite: false,
                               filename: "(auth)", detail: "authentication failed", failed: true))
            return
        }
        guard let (channel, request) = openChannel(session) else {
            return
        }
        defer { ssh_channel_free(channel) }

        switch request {
        case .sftp:
            guard let sftp = sftp_server_new(session, channel), sftp_server_init(sftp) == SSH_OK else {
                return
            }
            defer { sftp_free(sftp) }
            let handler = SFTPRequestHandler(sftp: sftp, root: URL(fileURLWithPath: config.rootPath),
                                             allowWrites: allowWrites, peer: peer, onLog: onLog,
                                             onProgress: onProgress)
            handler.loop()
        case .scp(let command):
            // Same SSH server also answers `copy scp://user@mac:port/…`.
            SCPServerHandler(channel: channel, command: command,
                             root: URL(fileURLWithPath: config.rootPath),
                             allowWrites: allowWrites, peer: peer, onLog: onLog,
                             onProgress: onProgress).run()
        }
    }

    private enum ChannelRequest {
        case sftp
        case scp(String)
    }

    private static func authenticate(_ session: ssh_session, config: Config) -> Bool {
        while true {
            guard let message = ssh_message_get(session) else {
                return false
            }
            defer { ssh_message_free(message) }
            let type = ssh_message_type(message)
            if type == SSH_REQUEST_AUTH.rawValue {
                let subtype = ssh_message_subtype(message)
                if subtype == Int32(SSH_AUTH_METHOD_PASSWORD) {
                    let user = String(cString: ssh_message_auth_user(message))
                    let pass = String(cString: ssh_message_auth_password(message))
                    if user == config.username && pass == config.password && !pass.isEmpty {
                        ssh_message_auth_reply_success(message, 0)
                        return true
                    }
                }
                ssh_message_auth_set_methods(message, Int32(SSH_AUTH_METHOD_PASSWORD))
                ssh_message_reply_default(message)
            } else {
                ssh_message_reply_default(message)
            }
        }
    }

    private static func openChannel(_ session: ssh_session) -> (ssh_channel, ChannelRequest)? {
        var channel: ssh_channel?
        // First: a channel-open of type "session".
        while channel == nil {
            guard let message = ssh_message_get(session) else { return nil }
            if ssh_message_type(message) == SSH_REQUEST_CHANNEL_OPEN.rawValue,
               ssh_message_subtype(message) == SSH_CHANNEL_SESSION.rawValue {
                channel = ssh_message_channel_request_open_reply_accept(message)
                ssh_message_free(message)
            } else {
                ssh_message_reply_default(message)
                ssh_message_free(message)
            }
        }
        guard let channel else { return nil }
        // Then: either a "subsystem sftp" request, or an "exec scp …" request.
        while true {
            guard let message = ssh_message_get(session) else { return nil }
            let isChannelReq = ssh_message_type(message) == SSH_REQUEST_CHANNEL.rawValue
            let subtype = ssh_message_subtype(message)
            if isChannelReq, subtype == SSH_CHANNEL_REQUEST_SUBSYSTEM.rawValue,
               let raw = ssh_message_channel_request_subsystem(message),
               String(cString: raw) == "sftp" {
                ssh_message_channel_request_reply_success(message)
                ssh_message_free(message)
                return (channel, .sftp)
            }
            if isChannelReq, subtype == SSH_CHANNEL_REQUEST_EXEC.rawValue {
                let raw = ssh_message_channel_request_command(message)
                let command = raw.map { String(cString: $0) } ?? "<nil>"
                if command.hasPrefix("scp") {
                    ssh_message_channel_request_reply_success(message)
                    ssh_message_free(message)
                    return (channel, .scp(command))
                }
            }
            ssh_message_reply_default(message)
            ssh_message_free(message)
        }
    }

    private static func peerString(_ session: ssh_session) -> String {
        let fd = ssh_get_fd(session)
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len) == 0
            }
        }
        guard ok else { return "?" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return String(cString: host)
    }
}
