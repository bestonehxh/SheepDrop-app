import Combine
import Foundation

enum TransferProtocolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp
    case ftp
    case scp
    case tftp

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var defaultPort: Int {
        switch self {
        case .sftp, .scp: 22
        case .ftp: 21
        case .tftp: 69
        }
    }
    /// SFTP and FTP can list a remote directory, so they get the dual-pane
    /// browser. SCP and TFTP have no listing operation in the protocol, so
    /// their tabs use the quick-transfer form.
    var canBrowse: Bool { self == .sftp || self == .ftp }
}

struct HostEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var address: String = ""
    var port: Int = 22
    var username: String = ""
    var proto: TransferProtocolKind = .sftp

    var displayName: String { name.isEmpty ? address : name }
}

struct HostGroup: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var hosts: [HostEntry] = []
}

struct TransferRecord: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var detail: String
    var isUpload: Bool
    var finished: Date
    var failed: Bool
    var bytes: Int64
}

enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(cipher: String)
    case failed(String)

    var shortText: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

/// One open tab: a host plus its live connection state.
@MainActor
final class SessionTab: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let host: HostEntry
    @Published var status: ConnectionStatus = .disconnected
    /// Live SFTP connection — owned here, not by the view, so it survives
    /// tab switches. nil for protocols the SFTP engine doesn't serve.
    let sftp: SFTPSession?
    private var sessionObserver: AnyCancellable?

    init(host: HostEntry) {
        self.host = host
        // One session object serves SFTP, SCP and FTP (it branches on the
        // protocol internally); TFTP uses the quick-transfer form instead.
        self.sftp = host.proto != .tftp ? SFTPSession(host: host) : nil
        sftp?.bind(to: self)
        // ConnectionView observes the *tab*, not the session, but its toolbar
        // (breadcrumb, parent-folder enabled state, item count) and password
        // sheet read session state. Forward the session's change notifications
        // so navigating the remote pane keeps them current — without this the
        // toolbar froze at whatever it showed when tab.status last changed
        // (parent-folder button stuck disabled, breadcrumb stuck at the connect
        // path, and the interactive Connect button never presented the prompt).
        sessionObserver = sftp?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func shutdown() {
        sftp?.disconnect()
    }

    var title: String { "\(host.displayName) · \(host.proto.label)" }
}
