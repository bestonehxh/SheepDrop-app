import Combine
import Network
import SwiftUI

/// MainActor face of one SFTP connection. Owned by SessionTab so the
/// connection survives tab switches (the views are recreated per tab via
/// .id(tab.id), so nothing connection-shaped may live in view @State).
@MainActor
final class SFTPSession: ObservableObject {
    /// The username is editable from the password prompt (a saved host may
    /// carry the wrong one); everything else is fixed for the session.
    @Published private(set) var host: HostEntry
    private weak var tab: SessionTab?
    private let worker = SFTPWorker()
    private let ftp = FTPWorker()
    private var isFTP: Bool { host.proto == .ftp }

    /// True once an SCP connection has opened the SFTP subsystem for browsing
    /// (WinSCP-style). Meaningless for SFTP/FTP (already browsable) and TFTP.
    @Published private(set) var scpBrowsable = false

    /// Whether the dual-pane remote browser is available for this session.
    /// SFTP/FTP always; SCP only when the subsystem opened. Drives the UI's
    /// choice between the file browser and the blind put/get pane.
    var isBrowsable: Bool { host.proto.canBrowse || scpBrowsable }

    @Published var path = "/"
    @Published var entries: [FileEntry] = []
    @Published var selection: String?
    @Published var isLoading = false
    @Published var notice: String?
    /// Presents the password sheet.
    @Published var needsPassword = false
    @Published var authError: String?
    @Published var transfer: TransferState? {
        // The Transfers drawer and the sidebar badge observe AppModel, not each
        // session — so without this poke a transfer's live row/progress never
        // appeared there (it only showed up as "Done" once recordTransfer fired
        // at the end). Coalesced to ~10/s by the progress throttle upstream, so
        // this is cheap.
        didSet {
            AppModel.shared.transfersDidChange()
            // Auto-open the drawer when a transfer STARTS so the live
            // MB/percent bar is visible without hunting for it.
            if transfer != nil, oldValue == nil {
                AppModel.shared.drawerOpen = true
            }
        }
    }

    struct TransferState {
        var name: String
        var isUpload: Bool
        var done: Int64
        var total: Int64

        var fraction: Double? {
            total > 0 ? Double(done) / Double(total) : nil
        }
    }

    private var hasStarted = false

    init(host: HostEntry) {
        self.host = host
    }

    /// True once a connection has actually succeeded — a Cancel before that
    /// tears the whole tab down (nothing was ever established).
    private(set) var everConnected = false

    func bind(to tab: SessionTab) {
        self.tab = tab
    }

    func updateUsername(_ username: String) {
        host.username = username
    }

    /// Cancel from the password sheet. Closes the sheet; if the session never
    /// connected, closes the tab too so a cancelled connect leaves nothing
    /// behind (matches SheepTerm).
    func cancelConnect() {
        needsPassword = false
        authError = nil
        if !everConnected, let tab {
            AppModel.shared.closeTab(tab)
        }
    }

    /// First appearance of the pane. Auto-connects ONLY when a password is
    /// already stored (the seamless repeat case). With no stored password it
    /// does NOT pop the modal — the pane shows a Connect button instead, so
    /// clicking around the sidebar never throws surprise dialogs.
    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        // Deferred one tick: called from onAppear during the first render
        // pass; publishing state mid-update is a view-update violation.
        Task { @MainActor in
            if let devPassword = Self.devArgument("-demoPassword") {
                connect(password: devPassword, remember: false)
            } else {
                // Keychain read off the main thread — SecItemCopyMatching is an
                // IPC round-trip and the call that blocks on the SecurityAgent
                // prompt when a re-signed binary reads an old item.
                let account = Keychain.account(for: host)
                if let stored = await Task.detached(operation: { Keychain.password(account: account) }).value {
                    connect(password: stored, remember: false)
                }
            }
            // else: stay disconnected; the pane's Connect button prompts.
        }
    }

    /// Explicit user request to connect (Connect button / retry) — this is
    /// where the password sheet comes from.
    func beginInteractiveConnect() {
        let account = Keychain.account(for: host)
        Task { @MainActor in
            if let stored = await Task.detached(operation: { Keychain.password(account: account) }).value {
                connect(password: stored, remember: false)
            } else {
                needsPassword = true
            }
        }
    }

    /// `-flag value` from the launch arguments; dev hooks only.
    private static func devArgument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Retry entry point for the Connect button after cancel/failure.
    func retry() {
        hasStarted = true
        beginInteractiveConnect()
    }

    /// The password sheet stays OPEN during the attempt (spinner + inline
    /// error) and only closes itself on success — dismiss-then-represent on
    /// failure raced the dismissal animation and desynced the sheet state.
    func connect(password: String?, remember: Bool) {
        tab?.status = .connecting
        isLoading = true
        authError = nil
        let config = SFTPConfig(host: host.address, port: host.port,
                                username: host.username, password: password,
                                knownHostsPath: Self.devArgument("-demoKnownHosts"))
        Task {
            do {
                var hostKeyNotice: String?
                if isFTP {
                    try await ftp.connect(FTPWorker.Config(
                        host: host.address, port: host.port,
                        username: host.username.isEmpty ? "anonymous" : host.username,
                        password: password))
                } else if host.proto == .scp {
                    // WinSCP-style: try the SFTP subsystem for browsing; fall
                    // back to blind SCP put/get if the device refuses it.
                    let result = try await worker.connectSCP(config)
                    hostKeyNotice = result.notice
                    scpBrowsable = result.browsable
                } else {
                    hostKeyNotice = try await worker.connect(config)
                }
                if remember, let password, !password.isEmpty {
                    // securityd IPC (and a possible re-sign prompt) can block —
                    // keep it off the main actor, like the read path already is.
                    let account = Keychain.account(for: host)
                    await Task.detached { _ = Keychain.setPassword(password, account: account) }.value
                }
                notice = hostKeyNotice
                tab?.status = .connected(cipher: "")
                authError = nil
                needsPassword = false
                everConnected = true
                if host.proto == .scp && !scpBrowsable {
                    isLoading = false        // blind SCP — no listing
                } else if isFTP {
                    let home = (try? await ftp.currentDirectory()) ?? "/"
                    await load(home)
                } else {
                    // SFTP, or SCP with the subsystem open — browse over SFTP.
                    let home = (try? await worker.homeDirectory()) ?? "/"
                    await load(home)
                }
            } catch let error as SFTPError where error.isAuthFailure {
                isLoading = false
                tab?.status = .disconnected
                authError = password == nil || password?.isEmpty == true
                    ? nil : error.message
                // A stored password that no longer works must not loop
                // silently — drop it and ask. Off the main actor (securityd IPC).
                let account = Keychain.account(for: host)
                await Task.detached { Keychain.deletePassword(account: account) }.value
                needsPassword = true
            } catch {
                isLoading = false
                tab?.status = .failed(shortMessage(error))
                // Non-auth failure while the sheet is up: close it so the
                // placeholder shows the error and its retry button.
                needsPassword = false
            }
        }
    }

    func disconnect() {
        worker.disconnect()
        ftp.disconnect()
        tab?.status = .disconnected
        entries = []
        hasStarted = false
    }

    // MARK: - Browsing

    func refresh() {
        Task { await load(path) }
    }

    func enter(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        Task { await load(joined(path, entry.name)) }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }

    /// Jump to an arbitrary path typed in the address bar (WinSCP-style). Empty
    /// or "~" go to the login directory; a relative path is taken from the
    /// current folder.
    func open(_ rawPath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        Task {
            let target: String
            if trimmed.isEmpty || trimmed == "~" {
                // Home is protocol-specific — the SFTP worker isn't connected on
                // an FTP session, so ask the FTP control channel there.
                target = isFTP
                    ? ((try? await ftp.currentDirectory()) ?? "/")
                    : ((try? await worker.homeDirectory()) ?? "/")
            } else if trimmed.hasPrefix("/") {
                target = trimmed
            } else {
                target = joined(path, trimmed)
            }
            await load(target)
        }
    }

    private func load(_ newPath: String) async {
        isLoading = true
        do {
            let listing = isFTP
                ? try await ftp.list(newPath)
                : try await worker.listDirectory(newPath)
            path = newPath
            entries = listing
            selection = nil
        } catch {
            report(error)
        }
        isLoading = false
    }

    // MARK: - Transfers

    /// Coalesces per-chunk progress callbacks (which arrive hundreds of times a
    /// second — every publish re-renders ConnectionView via the SessionTab
    /// objectWillChange forward) down to ~10 publishes a second. Every tick is
    /// still recorded, so `finalDone` is exact even when its publish was
    /// skipped. Thread-safe: workers call from their own queues.
    nonisolated private final class ProgressThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPublish = DispatchTime(uptimeNanoseconds: 0)
        private var done: Int64 = 0

        /// Records the tick; true when it should reach the UI (≥100 ms since
        /// the previous publish, or the final byte of a known-length transfer).
        func note(_ d: Int64, _ t: Int64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            done = d
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastPublish.uptimeNanoseconds >= 100_000_000
                || (t > 0 && d >= t) {
                lastPublish = now
                return true
            }
            return false
        }

        var finalDone: Int64 { lock.lock(); defer { lock.unlock() }; return done }
    }

    func upload(localURL: URL) {
        let remotePath = joined(path, localURL.lastPathComponent)
        transfer = TransferState(name: localURL.lastPathComponent, isUpload: true, done: 0, total: 0)
        Task {
            do {
                let throttle = ProgressThrottle()
                let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
                    guard throttle.note(done, total) else { return }
                    Task { @MainActor in
                        self?.transfer = TransferState(
                            name: localURL.lastPathComponent, isUpload: true, done: done, total: total)
                    }
                }
                if isFTP {
                    try await ftp.upload(localURL: localURL, to: remotePath, progress: progress)
                } else {
                    try await worker.upload(localURL: localURL, to: remotePath, progress: progress)
                }
                let sent = throttle.finalDone
                transfer = nil
                AppModel.shared.recordTransfer(
                    name: localURL.lastPathComponent,
                    detail: "\(host.proto.label) · \(host.displayName) \(path)",
                    isUpload: true, bytes: sent, failed: false)
                await load(path)
            } catch {
                transfer = nil
                AppModel.shared.recordTransfer(
                    name: localURL.lastPathComponent,
                    detail: "\(host.proto.label) · \(host.displayName) \(path)",
                    isUpload: true, bytes: 0, failed: true)
                report(error, prefix: "Upload failed: ")
            }
        }
    }

    /// Downloads the remote selection into `localDirectory`, then calls
    /// `completion` (the local pane reloads itself there).
    func download(entryName: String, into localDirectory: URL,
                  completion: @escaping @MainActor () -> Void) {
        let remotePath = joined(path, entryName)
        let localURL = localDirectory.appendingPathComponent(entryName)
        transfer = TransferState(name: entryName, isUpload: false, done: 0, total: 0)
        Task {
            do {
                let throttle = ProgressThrottle()
                let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
                    guard throttle.note(done, total) else { return }
                    Task { @MainActor in
                        self?.transfer = TransferState(
                            name: entryName, isUpload: false, done: done, total: total)
                    }
                }
                if isFTP {
                    try await ftp.download(remotePath: remotePath, to: localURL, progress: progress)
                } else {
                    try await worker.download(remotePath: remotePath, to: localURL, progress: progress)
                }
                let got = throttle.finalDone
                transfer = nil
                AppModel.shared.recordTransfer(
                    name: entryName,
                    detail: "\(host.proto.label) · \(host.displayName) → local",
                    isUpload: false, bytes: got, failed: false)
                completion()
            } catch {
                transfer = nil
                AppModel.shared.recordTransfer(
                    name: entryName,
                    detail: "\(host.proto.label) · \(host.displayName) → local",
                    isUpload: false, bytes: 0, failed: true)
                report(error, prefix: "Download failed: ")
            }
        }
    }

    // MARK: - SCP transfers (quick-transfer form)

    func scpPush(localURL: URL, remotePath: String,
                 completion: @escaping @MainActor (String?) -> Void) {
        transfer = TransferState(name: localURL.lastPathComponent, isUpload: true, done: 0, total: 0)
        Task {
            do {
                let throttle = ProgressThrottle()
                try await worker.scpUpload(localURL: localURL, to: remotePath) { [weak self] done, total in
                    guard throttle.note(done, total) else { return }
                    Task { @MainActor in
                        self?.transfer = TransferState(
                            name: localURL.lastPathComponent, isUpload: true, done: done, total: total)
                    }
                }
                transfer = nil
                completion(nil)
            } catch {
                transfer = nil
                completion(shortMessage(error))
            }
        }
    }

    func scpPull(remotePath: String, into localDirectory: URL,
                 completion: @escaping @MainActor (String?) -> Void) {
        let name = (remotePath as NSString).lastPathComponent
        let localURL = localDirectory.appendingPathComponent(name.isEmpty ? "download" : name)
        transfer = TransferState(name: name, isUpload: false, done: 0, total: 0)
        Task {
            do {
                let throttle = ProgressThrottle()
                try await worker.scpDownload(remotePath: remotePath, to: localURL) { [weak self] done, total in
                    guard throttle.note(done, total) else { return }
                    Task { @MainActor in
                        self?.transfer = TransferState(name: name, isUpload: false, done: done, total: total)
                    }
                }
                transfer = nil
                completion(nil)
            } catch {
                transfer = nil
                completion(shortMessage(error))
            }
        }
    }

    // MARK: - Helpers

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func shortMessage(_ error: Error) -> String {
        (error as? SFTPError)?.message ?? error.localizedDescription
    }

    /// True when an error means the transport itself is gone — the server
    /// dropped the control connection (e.g. FTP idle timeout), or the socket
    /// was reset/closed — as opposed to a per-operation failure like a missing
    /// file or a permission denial, where the connection is still good.
    private func isConnectionLost(_ error: Error) -> Bool {
        let dead: [POSIXErrorCode] = [.ENOTCONN, .ECONNRESET, .EPIPE,
                                      .ETIMEDOUT, .ECONNABORTED, .ENETDOWN, .ENETRESET]
        if let nw = error as? NWError, case let .posix(code) = nw {
            return dead.contains(code)
        }
        if let posix = error as? POSIXError { return dead.contains(posix.code) }
        if let message = (error as? SFTPError)?.message.lowercased() {
            // libssh reports a dropped transport with strings like
            // "Socket error: Connection reset by peer" / "Timeout" — wrapped by
            // doList as "cannot open <path>: <that>". Match the real transport-
            // death tokens, not just the three we happened to see first, or a
            // mid-session reset leaves the tab stuck "connected" on a stale list.
            let dead = ["not connected", "connection closed", "disconnect",
                        "socket error", "reset by peer", "connection reset",
                        "broken pipe", "timed out", "timeout", "no route to host",
                        "network is down", "network is unreachable",
                        "connection refused", "end of file", "channel is closed"]
            return dead.contains { message.contains($0) }
        }
        return false
    }

    /// Sets the operation notice, and — if the error means the connection is
    /// gone — tears the dead transport down and flips the tab to disconnected
    /// so the reconnect overlay appears. Without this a server-side drop left
    /// the pane showing "connected" with a stale listing and every action
    /// failing with "socket is not connected" and no way back but closing the
    /// tab.
    private func report(_ error: Error, prefix: String = "") {
        notice = "\(prefix)\(shortMessage(error))"
        guard isConnectionLost(error) else { return }
        worker.disconnect()
        ftp.disconnect()
        entries = []
        selection = nil
        tab?.status = .disconnected
    }
}

/// Modal password prompt shown by the dual-pane view.
struct PasswordPromptSheet: View {
    @ObservedObject var session: SFTPSession
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var remember = true

    init(session: SFTPSession) {
        self.session = session
        _username = State(initialValue: session.host.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to \(session.host.displayName)")
                .font(.system(size: 14, weight: .medium))
            Text("\(session.host.address):\(String(session.host.port)) · \(session.host.proto.label)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            if let authError = session.authError {
                Text(authError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.err)
            }
            Toggle("Remember in Keychain", isOn: $remember)
                .font(.system(size: 12))
            HStack(spacing: 10) {
                if session.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                    session.cancelConnect()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isLoading)
                // No dismiss here: the sheet stays up through the attempt and
                // closes itself on success (session sets needsPassword=false).
                // Dismissing early raced the re-present after a failure.
                Button("Connect") {
                    session.updateUsername(username.trimmingCharacters(in: .whitespaces))
                    session.connect(password: password, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isLoading || password.isEmpty
                    || username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled(session.isLoading)
    }
}
