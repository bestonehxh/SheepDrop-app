import AppKit
import Combine
import SwiftUI

/// Central app state, mirrored on SheepTerm's AppModel: every view reads and
/// drives this one object. Single window only.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// What the main column shows: a connection, the Transfers screen, or
    /// the Serve screen (design v2 sidebar Activity section).
    enum MainPane: Equatable {
        case connection
        case transfers
        case serve
    }

    @Published var tabs: [SessionTab] = []
    @Published var selectedTabID: UUID?
    @Published var mainPane: MainPane = .connection
    @Published var drawerOpen = false
    @Published var transferHistory: [TransferRecord] = []

    /// Re-render views that observe AppModel (Transfers drawer, sidebar badge)
    /// when a session's live transfer state changes. See SFTPSession.transfer.
    func transfersDidChange() { objectWillChange.send() }

    func recordTransfer(name: String, detail: String, isUpload: Bool,
                        bytes: Int64, failed: Bool) {
        transferHistory.insert(
            TransferRecord(name: name, detail: detail, isUpload: isUpload,
                           finished: Date(), failed: failed, bytes: bytes),
            at: 0)
        if transferHistory.count > 100 {
            transferHistory.removeLast(transferHistory.count - 100)
        }
    }
    /// Kept in sync by FullscreenSync; drives the traffic-light spacer.
    @Published var isFullScreen = false
    @Published var sidebarWidth: CGFloat = UserDefaults.standard.object(forKey: "sidebarWidth") as? CGFloat ?? 220
    @Published var groups: [HostGroup]
    @Published var recents: [HostEntry]
    @Published var showQuickConnect = false
    /// Preselects a group in the QuickConnect sheet (from a group's
    /// "New Host in …" menu). Consumed and cleared by the sheet.
    var pendingGroupID: UUID?

    // TFTP server is global app state, not tied to any tab.
    @Published var tftpServerRunning = false
    @Published var tftpActualPort: UInt16?
    @Published var tftpLog: [TFTPLogEntry] = []
    /// The transfer a device is currently pulling/pushing on any built-in
    /// server, shown as a live bar under the Serve request log. Nil = idle.
    @Published var activeServeTransfer: ServeTransfer?
    @Published var tftpStartError: String?
    @Published var tftpRootPath: String = UserDefaults.standard.string(forKey: "tftpRoot")
        ?? (NSHomeDirectory() + "/TFTP-Root")
    private var tftpServer: TFTPServer?

    // Built-in SFTP server (serve the same root over sftp://, like TFTP).
    @Published var sftpServerRunning = false
    @Published var sftpActualPort: UInt16?
    @Published var sftpStartError: String?
    @Published var sftpUsername: String = UserDefaults.standard.string(forKey: "sftpServerUser") ?? "sheepdrop"
    private var sftpServer: SFTPServerListener?

    // Built-in FTP server (cleartext; shares the served root + SSH login).
    @Published var ftpServerRunning = false
    @Published var ftpActualPort: UInt16?
    @Published var ftpStartError: String?
    private var ftpServer: FTPServer?
    static let ftpServerPort: UInt16 = 21
    // Port 22 first (what `copy scp:` / switches hard-code), 2222 fallback.
    static let sftpServerPort: UInt16 = 22
    private static let sftpKeychainAccount = "sftp-server-password"

    /// One SecItemCopyMatching, then cached — ServeView reads this on every
    /// render (and re-renders on every request-log line), so the uncached
    /// version did a Keychain IPC round-trip per frame while a server was busy.
    private var cachedServerPassword: String?

    var sftpServerPassword: String {
        // Dev hook: bypass the Keychain (a CLI-injected item triggers a
        // blocking access prompt on the main thread during launch).
        if let index = CommandLine.arguments.firstIndex(of: "-demoSFTPPassword"),
           CommandLine.arguments.indices.contains(index + 1) {
            return CommandLine.arguments[index + 1]
        }
        if let cached = cachedServerPassword { return cached }
        let value = Keychain.password(account: Self.sftpKeychainAccount) ?? ""
        cachedServerPassword = value
        return value
    }

    func setSFTPUsername(_ name: String) {
        sftpUsername = name
        UserDefaults.standard.set(name, forKey: "sftpServerUser")
    }

    func setSFTPPassword(_ password: String) {
        cachedServerPassword = password
        objectWillChange.send()     // the ••• placeholder state changed
        // securityd IPC off the main actor (matches the client-side fix).
        let account = Self.sftpKeychainAccount
        Task.detached { _ = Keychain.setPassword(password, account: account) }
    }

    let hostStore = HostStore()

    private init() {
        groups = hostStore.loadGroups()
        recents = hostStore.loadRecents()
        // Dev hook: `open SheepDrop.app --args -demoTabs [tftp]` opens a tab
        // per protocol at launch so UI states can be captured without driving
        // the app. No effect in normal launches.
        if CommandLine.arguments.contains("-demoTabs") {
            let all = groups.flatMap(\.hosts)
            let wanted: TransferProtocolKind =
                CommandLine.arguments.contains("tftp") ? .tftp
                : CommandLine.arguments.contains("scp") ? .scp : .sftp
            for kind in TransferProtocolKind.allCases {
                if let host = all.first(where: { $0.proto == kind }) {
                    openTab(for: host)
                }
            }
            if let tab = tabs.first(where: { $0.host.proto == wanted }) {
                selectedTabID = tab.id
            }
        }
        // Dev hooks (value required — balanced-pairs rule in CLAUDE.md).
        if CommandLine.arguments.contains("-demoTFTPServer") {
            setTFTPServer(on: true)
        }
        if CommandLine.arguments.contains("-demoSFTPServer") {
            setSFTPServer(on: true)
        }
        if CommandLine.arguments.contains("-demoFTPServer") {
            setFTPServer(on: true)
        }
        if let index = CommandLine.arguments.firstIndex(of: "-demoPane"),
           CommandLine.arguments.indices.contains(index + 1) {
            switch CommandLine.arguments[index + 1] {
            case "serve": mainPane = .serve
            case "transfers": mainPane = .transfers
            default: break
            }
        }
    }

    var selectedTab: SessionTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func openTab(for host: HostEntry) {
        let tab = SessionTab(host: host)
        tabs.append(tab)
        selectedTabID = tab.id
        noteRecent(host)
    }

    func closeTab(_ tab: SessionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.shutdown()
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id
                : tabs.last?.id
        }
    }

    // MARK: - Host management (sidebar context menus)

    func deleteHost(_ host: HostEntry) {
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        hostStore.saveGroups(groups)
    }

    func moveHost(_ host: HostEntry, toGroup groupID: UUID) {
        guard let target = groups.firstIndex(where: { $0.id == groupID }),
              !groups[target].hosts.contains(where: { $0.id == host.id }) else { return }
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        groups[target].hosts.append(host)
        hostStore.saveGroups(groups)
    }

    func groupID(of host: HostEntry) -> UUID? {
        groups.first { $0.hosts.contains { $0.id == host.id } }?.id
    }

    func deleteGroup(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
        hostStore.saveGroups(groups)
    }

    @discardableResult
    func addGroup(named name: String) -> UUID {
        let group = HostGroup(name: name)
        groups.append(group)
        hostStore.saveGroups(groups)
        return group.id
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name
        hostStore.saveGroups(groups)
    }

    /// Reorder a whole group up or down in the sidebar.
    func moveGroup(_ groupID: UUID, up: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let target = up ? index - 1 : index + 1
        guard groups.indices.contains(target) else { return }
        groups.swapAt(index, target)
        hostStore.saveGroups(groups)
    }

    // MARK: - Drag-and-drop reordering

    /// Move a host (by id) so it lands in `groupID` at `index` (clamped).
    /// Works within a group and across groups.
    func dropHost(_ hostID: UUID, intoGroup groupID: UUID, at index: Int) {
        guard let sourceGroup = groups.firstIndex(where: { $0.hosts.contains { $0.id == hostID } }),
              let sourceIndex = groups[sourceGroup].hosts.firstIndex(where: { $0.id == hostID }),
              let destGroup = groups.firstIndex(where: { $0.id == groupID })
        else { return }
        let host = groups[sourceGroup].hosts[sourceIndex]

        // Compute the insertion index in the destination's CURRENT array,
        // then adjust if we removed an earlier element from the same group.
        var target = max(0, min(index, groups[destGroup].hosts.count))
        groups[sourceGroup].hosts.remove(at: sourceIndex)
        if sourceGroup == destGroup && sourceIndex < target { target -= 1 }
        target = max(0, min(target, groups[destGroup].hosts.count))
        groups[destGroup].hosts.insert(host, at: target)
        hostStore.saveGroups(groups)
    }

    /// Reorder a group so it lands before `beforeGroupID` (or at the end when
    /// nil).
    func dropGroup(_ groupID: UUID, before beforeGroupID: UUID?) {
        guard groupID != beforeGroupID,
              let sourceIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups.remove(at: sourceIndex)
        if let beforeGroupID, let target = groups.firstIndex(where: { $0.id == beforeGroupID }) {
            groups.insert(group, at: target)
        } else {
            groups.append(group)
        }
        hostStore.saveGroups(groups)
    }

    func indexOfHost(_ hostID: UUID, inGroup groupID: UUID) -> Int? {
        groups.first { $0.id == groupID }?.hosts.firstIndex { $0.id == hostID }
    }

    /// Reorder a host within its group.
    func moveHost(_ host: HostEntry, up: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.hosts.contains { $0.id == host.id } }),
              let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == host.id })
        else { return }
        let target = up ? hostIndex - 1 : hostIndex + 1
        guard groups[groupIndex].hosts.indices.contains(target) else { return }
        groups[groupIndex].hosts.swapAt(hostIndex, target)
        hostStore.saveGroups(groups)
    }

    func removeRecent(_ host: HostEntry) {
        recents.removeAll { $0.id == host.id }
        hostStore.saveRecents(recents)
    }

    func addHost(_ host: HostEntry, toGroup groupID: UUID?) {
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].hosts.append(host)
        } else if groups.isEmpty {
            groups = [HostGroup(name: "My Devices", hosts: [host])]
        } else {
            groups[0].hosts.append(host)
        }
        hostStore.saveGroups(groups)
    }

    private func noteRecent(_ host: HostEntry) {
        recents.removeAll {
            $0.address == host.address && $0.port == host.port
                && $0.username == host.username && $0.proto == host.proto
        }
        recents.insert(host, at: 0)
        if recents.count > HostStore.maxRecents {
            recents.removeLast(recents.count - HostStore.maxRecents)
        }
        hostStore.saveRecents(recents)
    }

    func persistSidebarWidth() {
        UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth")
    }

    func setTFTPRoot(_ path: String) {
        tftpRootPath = path
        UserDefaults.standard.set(path, forKey: "tftpRoot")
        // A running server keeps serving the old root until restarted.
        if tftpServer != nil {
            setTFTPServer(on: false)
            setTFTPServer(on: true)
        }
        if sftpServer != nil {
            setSFTPServer(on: false)
            setSFTPServer(on: true)
        }
        if ftpServer != nil {
            setFTPServer(on: false)
            setFTPServer(on: true)
        }
    }

    // MARK: - FTP server lifecycle

    func setFTPServer(on: Bool) {
        if on {
            startFTPServer()
        } else {
            ftpServer?.stop()
            ftpServer = nil
            ftpServerRunning = false
            ftpActualPort = nil
            clearServeTransferIfAllStopped()
        }
    }

    /// Drop the held transfer row once nothing is serving.
    private func clearServeTransferIfAllStopped() {
        if !tftpServerRunning && !sftpServerRunning && !ftpServerRunning {
            activeServeTransfer = nil
        }
    }

    private func startFTPServer() {
        guard ftpServer == nil else { return }
        guard !sftpServerPassword.isEmpty else {
            ftpStartError = "Set the server username and password first (shared with SFTP)."
            return
        }
        let root = URL(fileURLWithPath: tftpRootPath)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = FTPServer.Config(
            port: Self.ftpServerPort,
            username: sftpUsername,
            password: sftpServerPassword,
            rootPath: tftpRootPath,
            allowWrites: UserDefaults.standard.bool(forKey: "tftpAllowWrites"))
        let server = FTPServer(
            config: config,
            // Live closure (same as TFTP) so the "Allow writes" checkbox
            // applies without a server restart.
            allowWrites: { UserDefaults.standard.bool(forKey: "tftpAllowWrites") },
            onLog: { entry in
                Task { @MainActor in AppModel.shared.appendServeLog(entry) }
            })
        ftpServer = server
        ftpStartError = nil
        Task {
            do {
                let port = try await server.start()
                guard ftpServer === server else { server.stop(); return }
                ftpActualPort = port
                ftpServerRunning = true
            } catch {
                guard ftpServer === server else { return }
                ftpServer = nil
                ftpServerRunning = false
                let message = (error as? SFTPError)?.message ?? error.localizedDescription
                ftpStartError = "Couldn't start: \(message)"
            }
        }
    }

    private func appendServeLog(_ entry: TFTPLogEntry) {
        tftpLog.insert(entry, at: 0)
        if tftpLog.count > 200 { tftpLog.removeLast(tftpLog.count - 200) }
    }

    /// A `@Sendable` progress sink for the servers (which run off the main
    /// actor). Hops each update to the main actor and drives the live bar.
    /// A completed (`.done`) transfer is KEPT as a history row until the next
    /// one starts; a `nil` finalize marks a still-`.active` bar as `.failed`.
    nonisolated static func serveProgressSink() -> ServeProgress {
        { transfer in
            Task { @MainActor in
                let model = AppModel.shared
                guard let transfer else { return }   // bare nil no longer used
                switch transfer.state {
                case .active:
                    // A late .active must not un-finish the SAME transfer's
                    // already-shown .done (unstructured Tasks aren't FIFO).
                    if let cur = model.activeServeTransfer, cur.id == transfer.id,
                       cur.state == .done { return }
                    model.activeServeTransfer = transfer
                case .done:
                    model.activeServeTransfer = transfer
                case .failed:
                    // Only update the bar if THIS transfer is the one shown —
                    // never fail an unrelated concurrent transfer, clobber a held
                    // .done, or resurrect a bar the server-stop already cleared.
                    guard let cur = model.activeServeTransfer, cur.id == transfer.id else { return }
                    model.activeServeTransfer = transfer
                }
            }
        }
    }

    // MARK: - SFTP server lifecycle

    func setSFTPServer(on: Bool) {
        if on {
            startSFTPServer()
        } else {
            sftpServer?.stop()
            sftpServer = nil
            sftpServerRunning = false
            sftpActualPort = nil
            clearServeTransferIfAllStopped()
        }
    }

    private func startSFTPServer() {
        guard sftpServer == nil else { return }
        guard !sftpServerPassword.isEmpty else {
            sftpStartError = "Set an SFTP username and password first."
            return
        }
        let root = URL(fileURLWithPath: tftpRootPath)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = SFTPServerListener.Config(
            port: Self.sftpServerPort,
            username: sftpUsername,
            password: sftpServerPassword,
            rootPath: tftpRootPath,
            allowWrites: UserDefaults.standard.bool(forKey: "tftpAllowWrites"))
        let server = SFTPServerListener(
            config: config,
            allowWrites: { UserDefaults.standard.bool(forKey: "tftpAllowWrites") },
            onLog: { entry in
                Task { @MainActor in AppModel.shared.appendServeLog(entry) }
            },
            onProgress: Self.serveProgressSink())
        sftpServer = server
        sftpStartError = nil
        Task {
            do {
                let port = try await server.start()
                // The user may have toggled off (and started a new server)
                // while the bind was in flight — only publish "running" if this
                // is still the current server, else stop the one we just bound.
                guard sftpServer === server else { server.stop(); return }
                sftpActualPort = port
                sftpServerRunning = true
            } catch {
                guard sftpServer === server else { return }
                sftpServer = nil
                sftpServerRunning = false
                let message = (error as? SFTPError)?.message ?? error.localizedDescription
                sftpStartError = "Couldn't start: \(message)"
            }
        }
    }

    // MARK: - TFTP server lifecycle

    func setTFTPServer(on: Bool) {
        if on {
            startTFTPServer()
        } else {
            tftpServer?.stop()
            tftpServer = nil
            tftpServerRunning = false
            tftpActualPort = nil
            clearServeTransferIfAllStopped()
        }
    }

    private func startTFTPServer() {
        guard tftpServer == nil else { return }
        let root = URL(fileURLWithPath: tftpRootPath)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = TFTPServer(
            root: root,
            allowWrites: { UserDefaults.standard.bool(forKey: "tftpAllowWrites") },
            onLog: { entry in
                Task { @MainActor in
                    let model = AppModel.shared
                    model.tftpLog.insert(entry, at: 0)
                    if model.tftpLog.count > 200 {
                        model.tftpLog.removeLast(model.tftpLog.count - 200)
                    }
                }
            },
            onProgress: Self.serveProgressSink())
        tftpServer = server
        tftpStartError = nil
        Task {
            do {
                let port = try await server.start()
                guard tftpServer === server else { server.stop(); return }
                tftpActualPort = port
                tftpServerRunning = true
            } catch {
                guard tftpServer === server else { return }
                tftpServer = nil
                tftpServerRunning = false
                tftpStartError = "Couldn't start: \(error.localizedDescription)"
            }
        }
    }
}
