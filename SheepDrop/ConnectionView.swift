import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One connection in the main column (design v2): 52pt toolbar with
/// breadcrumb + search + queue button, the local/remote dual pane (remote is
/// the blind put/get form for SCP and TFTP), the collapsible transfers
/// drawer, and the security status bar.
struct ConnectionView: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject private var model = AppModel.shared
    @StateObject private var localPane = LocalPaneModel()
    @State private var searchText = ""

    private var session: SFTPSession? { tab.sftp }
    /// Session-aware: SFTP/FTP always, SCP once its SFTP subsystem opened.
    private var canBrowse: Bool { session?.isBrowsable ?? false }
    private var isBlind: Bool { !canBrowse }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
            HSplitPanes(tab: tab, localPane: localPane, searchText: searchText)
            if let session { ActiveTransferBar(session: session) }
            TransfersDrawer()
            statusBar
        }
        .background(Theme.content, ignoresSafeAreaEdges: [])
        .onAppear { tab.sftp?.startIfNeeded() }
        .background {
            // The password sheet MUST be hosted by a view that observes the
            // session. ConnectionView observes only `tab`, so a bare
            // `.sheet(isPresented:)` reading session.needsPassword never
            // re-rendered when the Connect/retry button flipped it — the prompt
            // only appeared when a Keychain or -demoPassword path ALSO changed
            // tab.status and forced a redraw. This zero-size presenter
            // subscribes to the session directly.
            if let session { PasswordSheetPresenter(session: session) }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            ToolbarIcon(systemName: "chevron.up", enabled: canGoUp) {
                session?.goUp()
            }
            .help("Parent folder")

            // Breadcrumb pill
            HStack(spacing: 6) {
                Image(systemName: tab.host.proto == .tftp ? "lock.open" : "lock")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tab.host.proto == .tftp ? Theme.err : Theme.ok)
                Text(breadcrumbUser)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dimText)
                    .lineLimit(1)
                Text("›")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.disabledText)
                Text(remotePathText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.disabledText)
                TextField("Search this folder", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 9)
            .frame(width: 178, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))

            ToolbarIcon(systemName: "arrow.clockwise", enabled: true) {
                // A remote listing only exists for SFTP/FTP. On SCP/TFTP the
                // refresh reloads the local pane only — calling refresh() there
                // would fire a doomed SFTP list on a connection with no subsystem
                // and leave a notice BlindPane never surfaces.
                if canBrowse { session?.refresh() }
                localPane.reload()
            }

            // Queue toggle
            Button {
                model.drawerOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(activeTransferCount)")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(model.drawerOpen ? .white : Theme.text2)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(model.drawerOpen ? Theme.accent : Theme.control)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Theme.header, ignoresSafeAreaEdges: [])
    }

    private var canGoUp: Bool {
        guard let session, canBrowse else { return false }
        return session.path != "/"
    }

    private var breadcrumbUser: String {
        tab.host.username.isEmpty
            ? tab.host.address
            : "\(tab.host.username)@\(tab.host.address)"
    }

    private var remotePathText: String {
        if isBlind { return "(no path)" }
        return session?.path ?? "/"
    }

    private var activeTransferCount: Int {
        model.tabs.compactMap(\.sftp).filter { $0.transfer != nil }.count
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(securityLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dimText)
                .lineLimit(1)
            Spacer()
            Text(countLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faintText)
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.header, ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
        }
    }

    private var securityLine: String {
        let base: String
        switch tab.host.proto {
        case .sftp: base = "SFTP v3 over SSH-2"
        case .scp: base = "SCP over SSH-2"
        case .tftp: base = "TFTP RFC 1350 · UDP · no authentication, no encryption"
        case .ftp: base = "FTP"
        }
        switch tab.status {
        case .connected: return "\(base) · connected"
        case .connecting: return "\(base) · connecting…"
        case .failed(let message): return message
        case .disconnected: return "\(base) · not connected"
        }
    }

    private var countLine: String {
        guard canBrowse, let session else { return "" }
        return session.entries.isEmpty ? "" : "\(session.entries.count) items"
    }
}

/// Always-visible progress card shown in the connection view (above the
/// Transfers drawer) while a transfer is running — so the MB/percent bar is
/// front-and-center without opening the drawer.
struct ActiveTransferBar: View {
    @ObservedObject var session: SFTPSession

    var body: some View {
        if let t = session.transfer {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: t.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                    Text(t.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(readout(t))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.dimText)
                }
                ProgressView(value: t.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.header)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
            }
        }
    }

    private func readout(_ t: SFTPSession.TransferState) -> String {
        if let f = t.fraction {
            return "\(ByteFormat.string(t.done)) / \(ByteFormat.string(t.total)) · \(Int(f * 100))%"
        }
        return ByteFormat.string(t.done)
    }
}

/// Hosts the password sheet from a view that OBSERVES the session, so a
/// `needsPassword` toggle actually presents it (see ConnectionView.body).
private struct PasswordSheetPresenter: View {
    @ObservedObject var session: SFTPSession

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $session.needsPassword) {
                PasswordPromptSheet(session: session)
            }
    }
}

struct ToolbarIcon: View {
    let systemName: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Theme.dimText : Theme.disabledText.opacity(0.6))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && enabled ? Theme.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Panes

private struct HSplitPanes: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var localPane: LocalPaneModel
    let searchText: String

    var body: some View {
        HStack(spacing: 0) {
            LocalPaneView(localPane: localPane, searchText: searchText,
                          canUpload: canUpload, onUpload: upload)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            Group {
                if let session = tab.sftp, session.isBrowsable {
                    RemoteListPane(tab: tab, session: session, searchText: searchText,
                                   canDownload: canDownload, onDownload: download)
                } else {
                    BlindPane(tab: tab, localPane: localPane)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isConnectedSFTP: Bool {
        guard tab.sftp?.isBrowsable == true, case .connected = tab.status else { return false }
        return tab.sftp?.transfer == nil
    }

    private var selectedLocalFile: URL? {
        guard let name = localPane.selection else { return nil }
        let url = localPane.directoryURL.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    private var canUpload: Bool {
        isConnectedSFTP && selectedLocalFile != nil
    }

    private var canDownload: Bool {
        guard isConnectedSFTP, let session = tab.sftp,
              let name = session.selection,
              let entry = session.entries.first(where: { $0.name == name }) else { return false }
        return !entry.isDirectory
    }

    private func upload() {
        guard let url = selectedLocalFile else { return }
        tab.sftp?.upload(localURL: url)
    }

    private func download() {
        guard let session = tab.sftp, let name = session.selection else { return }
        session.download(entryName: name, into: localPane.directoryURL) {
            localPane.reload()
        }
    }
}

struct LocalPaneView: View {
    @ObservedObject var localPane: LocalPaneModel
    let searchText: String
    var canUpload = false
    var onUpload: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimText)
                Text("This Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                // Editable address bar: type a path (or `..`) + Enter to cd.
                EditablePathField(path: localPane.displayPath) { localPane.open($0) }
                Button {
                    localPane.chooseDirectory()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dimText)
                }
                .buttonStyle(.plain)
                .help("Choose a folder…")
                Button {
                    localPane.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dimText)
                }
                .buttonStyle(.plain)
                .help("Parent folder (cd ..)")
                Button(action: onUpload) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(canUpload ? Theme.accent : Theme.disabledText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canUpload)
                .help("Upload selected file")
            }
            FileColumnHeader(showPerms: false)
            FileListView(
                entries: filtered(localPane.entries),
                selection: $localPane.selection,
                showPerms: false,
                onOpen: { localPane.enter($0) }
            )
        }
    }

    private func filtered(_ entries: [FileEntry]) -> [FileEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

struct RemoteListPane: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var session: SFTPSession
    let searchText: String
    var canDownload = false
    var onDownload: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                ProtoBadge(proto: tab.host.proto)
                Text(tab.host.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                // Editable address bar for the device side: type a remote path
                // (or `..`) + Enter to cd there.
                EditablePathField(path: session.path) { session.open($0) }
                if session.isLoading {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    session.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.path == "/" ? Theme.disabledText.opacity(0.5) : Theme.dimText)
                }
                .buttonStyle(.plain)
                .disabled(session.path == "/")
                .help("Parent folder (cd ..)")
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(canDownload ? Theme.accent : Theme.disabledText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
                .help("Download selected file into the local folder")
            }
            // Perms column only when the pane is wide enough — squeezed
            // columns ate the whole Name column at the minimum window size.
            GeometryReader { geo in
                let showPerms = geo.size.width >= 430
                VStack(spacing: 0) {
                    FileColumnHeader(showPerms: showPerms)
                    ZStack {
                        FileListView(
                            entries: filtered(session.entries),
                            selection: $session.selection,
                            showPerms: showPerms,
                            onOpen: { session.enter($0) }
                        )
                        if case .connected = tab.status {} else {
                            RemoteDisconnectedOverlay(tab: tab)
                        }
                    }
                }
            }
            if let notice = session.notice {
                NoticeBar(text: notice) { session.notice = nil }
            }
        }
    }

    private func filtered(_ entries: [FileEntry]) -> [FileEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

/// A path shown in a pane header that doubles as a `cd`-style address bar:
/// looks like the plain path until focused, accepts a typed path (absolute,
/// `~`, or relative with `..`) and navigates on Return. Stays in sync with the
/// pane's current path while not being edited.
struct EditablePathField: View {
    let path: String
    let onGo: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("path", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(focused ? Theme.text : Theme.disabledText)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            .onSubmit { onGo(draft); focused = false }
            .onChange(of: path) { _, newPath in if !focused { draft = newPath } }
            .onChange(of: focused) { _, isFocused in if !isFocused { draft = path } }
            .onAppear { draft = path }
    }
}

struct PaneStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.header, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
        }
    }
}

struct ProtoBadge: View {
    let proto: TransferProtocolKind

    var body: some View {
        Text(proto.label)
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.3)
            .foregroundStyle(Theme.protoColor(proto))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.protoColor(proto).opacity(0.12))
            )
    }
}

struct RemoteDisconnectedOverlay: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        VStack(spacing: 14) {
            if case .connecting = tab.status {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dimText)
            } else {
                RoundedRectangle(cornerRadius: 13)
                    .fill(hasFailed ? Theme.err.opacity(0.12) : Theme.well)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: hasFailed ? "exclamationmark.triangle" : "server.rack")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(hasFailed ? Theme.err : Theme.faintText)
                    )
                Text(hasFailed ? "Couldn’t connect" : "Not connected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if hasFailed {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dimText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                Button {
                    tab.sftp?.retry()
                } label: {
                    Text(hasFailed ? "Try Again" : "Connect")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.content)
    }

    private var hasFailed: Bool {
        if case .failed = tab.status { return true }
        return false
    }

    private var statusText: String {
        if case .failed(let message) = tab.status { return message }
        return "Not connected"
    }
}

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10.5))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.dimText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.header)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
        }
    }
}

// MARK: - Blind pane (SCP / TFTP / FTP-until-built)

struct BlindPane: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var localPane: LocalPaneModel
    @State private var remoteName = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    private var session: SFTPSession? { tab.sftp }
    private var isSCP: Bool { tab.host.proto == .scp }

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                ProtoBadge(proto: tab.host.proto)
                Text(tab.host.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Text("(no path)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.disabledText)
                Spacer(minLength: 0)
                if isSCP { scpStatus }
            }

            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Theme.well)
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: "eye.slash")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(Theme.faintText)
                        )
                    Text(blindTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(blindBody)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dimText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 360)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("REMOTE FILENAME")
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.3)
                            .foregroundStyle(Theme.faintText)
                        TextField(isSCP ? "flash:/image.swi or /var/log/messages"
                            : "ArubaCX-10.13-boot.swi", text: $remoteName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.content))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 0.5))
                        HStack(spacing: 8) {
                            BlindButton(title: "Put file", systemName: "arrow.up",
                                        prominent: true, enabled: canPut) { put() }
                            BlindButton(title: "Get file", systemName: "arrow.down",
                                        prominent: false, enabled: canGet) { get() }
                        }
                        if let transfer = session?.transfer {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(transferText(transfer))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.dimText)
                            }
                        } else if let feedback {
                            Text(feedback)
                                .font(.system(size: 11))
                                .foregroundStyle(feedbackIsError ? Theme.err : Theme.ok)
                                .lineLimit(3)
                        }
                        Text(blindFoot)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faintText)
                            .lineSpacing(2)
                    }
                    .frame(maxWidth: 400)
                }
                .padding(.horizontal, 44)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.content)
        }
    }

    @ViewBuilder
    private var scpStatus: some View {
        switch tab.status {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .connected:
            Circle().fill(Theme.live).frame(width: 7, height: 7)
        default:
            Button("Connect…") { session?.retry() }
                .controlSize(.small)
        }
    }

    private var blindTitle: String {
        isSCP ? "SCP is copy-only" : "TFTP has no directory listing"
    }

    private var blindBody: String {
        isSCP
            ? "This device serves SCP without the SFTP subsystem, so there is nothing to browse. Name the remote file and SheepDrop will PUT the selected local file or GET into the local folder."
            : "RFC 1350 defines only read and write of a named file. Name the file you want — no browsing, no rename, no delete."
    }

    private var blindFoot: String {
        if isSCP {
            let selected = localPane.selection.map { "PUT sends “\($0)”. " } ?? "Select a local file to PUT. "
            return selected + "GET saves into \(localPane.displayPath)."
        }
        return "The TFTP client lands in a later build — use Serve mode and let the device pull instead. With blksize 1468 a TFTP file caps at ~96 MB; anything larger goes over SFTP/SCP."
    }

    private var canPut: Bool {
        guard isSCP, isConnected, session?.transfer == nil,
              !remoteName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return selectedLocalFile != nil
    }

    private var canGet: Bool {
        isSCP && isConnected && session?.transfer == nil
            && !remoteName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isConnected: Bool {
        if case .connected = tab.status { return true }
        return false
    }

    private var selectedLocalFile: URL? {
        guard let name = localPane.selection else { return nil }
        let url = localPane.directoryURL.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    private func put() {
        guard let file = selectedLocalFile, let session else { return }
        feedback = nil
        let target = remoteName.trimmingCharacters(in: .whitespaces)
        session.scpPush(localURL: file, remotePath: target) { error in
            feedbackIsError = error != nil
            feedback = error ?? "Sent \(file.lastPathComponent) ✓"
            AppModel.shared.recordTransfer(
                name: file.lastPathComponent,
                detail: "SCP · \(tab.host.displayName) \(target)",
                isUpload: true, bytes: 0, failed: error != nil)
        }
    }

    private func get() {
        guard let session else { return }
        feedback = nil
        let target = remoteName.trimmingCharacters(in: .whitespaces)
        session.scpPull(remotePath: target, into: localPane.directoryURL) { error in
            feedbackIsError = error != nil
            feedback = error ?? "Saved into \(localPane.displayPath) ✓"
            localPane.reload()
            AppModel.shared.recordTransfer(
                name: (target as NSString).lastPathComponent,
                detail: "SCP · \(tab.host.displayName) → \(localPane.displayPath)",
                isUpload: false, bytes: 0, failed: error != nil)
        }
    }

    private func transferText(_ transfer: SFTPSession.TransferState) -> String {
        if let fraction = transfer.fraction {
            return "\(transfer.name) — \(ByteFormat.string(transfer.done)) / \(ByteFormat.string(transfer.total)) · \(Int(fraction * 100))%"
        }
        return "\(transfer.name) — \(ByteFormat.string(transfer.done))"
    }
}

struct BlindButton: View {
    let title: String
    let systemName: String
    var prominent: Bool
    var enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(prominent ? .white : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.control))
            )
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Transfers drawer

struct TransfersDrawer: View {
    @ObservedObject private var model = AppModel.shared

    private var liveTransfers: [(tab: SessionTab, transfer: SFTPSession.TransferState)] {
        model.tabs.compactMap { tab in
            guard let transfer = tab.sftp?.transfer else { return nil }
            return (tab, transfer)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible)
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.faintText)
                    .rotationEffect(.degrees(model.drawerOpen ? 90 : 0))
                Text("Transfers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faintText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.header)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { model.drawerOpen.toggle() }
            }

            if model.drawerOpen {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(liveTransfers, id: \.tab.id) { item in
                            LiveTransferRow(tab: item.tab)
                        }
                        ForEach(model.transferHistory.prefix(8)) { record in
                            HistoryTransferRow(record: record)
                        }
                        if liveTransfers.isEmpty && model.transferHistory.isEmpty {
                            Text("No transfers yet")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.faintText)
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(height: 138)
                .background(Theme.content)
            }
        }
    }

    private var summary: String {
        let active = liveTransfers.count
        if active > 0 { return "\(active) active" }
        let done = model.transferHistory.count
        return done == 0 ? "" : "\(done) recent"
    }
}

struct LiveTransferRow: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        if let session = tab.sftp, let transfer = session.transfer {
            HStack(spacing: 10) {
                TransferIcon(isUpload: transfer.isUpload, failed: false, active: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transfer.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(tab.host.proto.label) · \(tab.host.displayName)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faintText)
                }
                .frame(width: 230, alignment: .leading)
                ProgressView(value: transfer.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.protoColor(tab.host.proto))
                Text(progressText(transfer))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faintText)
                    .frame(width: 140, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
        }
    }

    private func progressText(_ transfer: SFTPSession.TransferState) -> String {
        if let fraction = transfer.fraction {
            // done / total · pct — the total tells the user how big the file is
            // and how far along the transfer is.
            return "\(ByteFormat.string(transfer.done)) / \(ByteFormat.string(transfer.total)) · \(Int(fraction * 100))%"
        }
        // Unknown total (server gave no SIZE): show bytes moved so far.
        return ByteFormat.string(transfer.done)
    }
}

struct HistoryTransferRow: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 10) {
            TransferIcon(isUpload: record.isUpload, failed: record.failed, active: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(record.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(1)
            }
            Spacer()
            Text(record.failed ? "Failed" : "Done")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(record.failed ? Theme.err : Theme.ok)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill((record.failed ? Theme.err : Theme.ok).opacity(0.14))
                )
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}

struct TransferIcon: View {
    let isUpload: Bool
    let failed: Bool
    let active: Bool

    var body: some View {
        Image(systemName: isUpload ? "arrow.up" : "arrow.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(failed ? Theme.err : active ? Theme.accent : Theme.faintText)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(failed ? Theme.err.opacity(0.12) : Theme.hover)
            )
    }
}
