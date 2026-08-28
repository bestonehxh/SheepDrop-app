import AppKit
import SwiftUI

/// The Serve screen (design v2 "ServerMode" artboard): let a switch,
/// firewall or router pull files from this Mac. Hosts the TFTP server
/// controls, the device-CLI command builder, and the request log.
struct ServeView: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage("tftpAllowWrites") private var allowWrites = false
    @AppStorage("serveTransport") private var transport = ServeTransport.tftp.rawValue
    @State private var copiedPull = false
    @State private var sftpPasswordDraft = ""
    /// getifaddrs is a syscall — resolve the Mac's IP once, not per body render.
    @State private var macIP = LocalNetwork.primaryIPv4() ?? "no network"

    /// SFTP and SCP are one SSH server, so they are a single choice
    /// ("SFTP / SCP"); TFTP and FTP are their own servers.
    enum ServeTransport: String {
        case tftp, ssh, ftp
        var label: String {
            switch self {
            case .tftp: "TFTP"
            case .ssh: "SFTP / SCP"
            case .ftp: "FTP"
            }
        }
        var usesSSHServer: Bool { self == .ssh }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(anyServerRunning ? Theme.ok : Theme.dimText)
                Text("Serve")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Text("Let a switch, firewall or router pull files from this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.disabledText)
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Minimal flow: pick protocol · configure + turn on ·
                    // watch the log. No command-builder — the address to reach
                    // this Mac is shown inline; the user types their own copy.
                    protocolStep
                    serverStep
                    logCard
                    transferCard
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.content)
        }
        .background(Theme.content, ignoresSafeAreaEdges: [])
    }

    private var anyServerRunning: Bool {
        model.tftpServerRunning || model.sftpServerRunning || model.ftpServerRunning
    }

    private var isTFTP: Bool { currentTransport == .tftp }
    private var usesSSHServer: Bool { currentTransport.usesSSHServer }

    // MARK: - Step 1: protocol

    private var protocolStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepHeader(1, "Choose how the device connects")
            Picker("", selection: $transport) {
                Text("TFTP").tag(ServeTransport.tftp.rawValue)
                Text("SFTP / SCP").tag(ServeTransport.ssh.rawValue)
                Text("FTP").tag(ServeTransport.ftp.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(protocolHint)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faintText)
                .lineSpacing(2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
    }

    private var protocolHint: String {
        switch currentTransport {
        case .tftp:
            return "No login, UDP port 69. Simplest and most widely supported; anyone on the segment can read the folder — use on a trusted path."
        case .ssh:
            return "One SSH server on port 22 (falls back to 2222 if the Mac's Remote Login owns 22) with a login. The device reaches it as either sftp:// or scp:// — use whichever its copy command supports; `copy scp:` on switches always uses port 22."
        case .ftp:
            return "Classic FTP with a login (port 21, falls back to 2121). CLEARTEXT — the password and files cross the network unencrypted, so prefer SFTP unless the device only speaks FTP. Shares the SFTP login."
        }
    }

    // MARK: - Step 2: configure the chosen server + turn it on

    private var needsLogin: Bool { currentTransport == .ssh || currentTransport == .ftp }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepHeader(2, "\(currentTransport.label) server")
                Spacer()
                Text(transportStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(selectedRunning ? Theme.ok : Theme.dimText)
                Toggle("", isOn: transportRunningBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            rootFolderRow
            HStack(spacing: 12) {
                Toggle("Allow writes (device backups)", isOn: $allowWrites)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
                Spacer()
                Text("This Mac: \(macIP)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.dimText)
            }
            if needsLogin { sftpCredentialRows }
            if let error = transportStartError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.err)
            }
            if selectedRunning { reachAddressRow }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
    }

    private var transportStatus: String {
        switch currentTransport {
        case .tftp: return tftpStatus
        case .ssh: return sftpStatus
        case .ftp:
            if model.ftpServerRunning, let port = model.ftpActualPort {
                return "Listening · port \(port)"
            }
            return "Off"
        }
    }

    private var transportRunningBinding: Binding<Bool> {
        switch currentTransport {
        case .tftp: return tftpRunningBinding
        case .ssh: return sftpRunningBinding
        case .ftp: return Binding(get: { model.ftpServerRunning }, set: { model.setFTPServer(on: $0) })
        }
    }

    private var transportStartError: String? {
        switch currentTransport {
        case .tftp: return model.tftpStartError
        case .ssh: return model.sftpStartError
        case .ftp: return model.ftpStartError
        }
    }

    /// The base URL a device uses to reach this Mac — the user appends their
    /// own filename and destination. One line, one copy button, no builder.
    private var reachAddressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ok)
            Text("Devices reach this at")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dimText)
            Text(reachURL)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reachURL, forType: .string)
                copiedPull = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedPull = false }
            } label: {
                Image(systemName: copiedPull ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copiedPull ? Theme.ok : Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Copy address")
            if usesSSHServer {
                Text("· scp:// too")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faintText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.content))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairlineSoft, lineWidth: 0.5))
    }

    private var reachURL: String {
        let ip = macIP == "no network" ? "<mac-ip>" : macIP
        switch currentTransport {
        case .tftp:
            let port = model.tftpActualPort
            let suffix = (port == nil || port == 69) ? "" : ":\(port!)"
            return "tftp://\(ip)\(suffix)/"
        case .ssh:
            let port = model.sftpActualPort ?? AppModel.sftpServerPort
            return "sftp://\(model.sftpUsername)@\(ip):\(port)/"
        case .ftp:
            let port = model.ftpActualPort ?? AppModel.ftpServerPort
            let suffix = port == 21 ? "" : ":\(port)"
            return "ftp://\(model.sftpUsername)@\(ip)\(suffix)/"
        }
    }

    private var rootFolderRow: some View {
        HStack(spacing: 8) {
            Text("Served folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dimText)
                .frame(width: 90, alignment: .leading)
            Text((model.tftpRootPath as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
            Button("Change…") { chooseRoot() }
                .buttonStyle(.link).font(.system(size: 11.5))
            Button("Open") {
                let url = URL(fileURLWithPath: model.tftpRootPath)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link).font(.system(size: 11.5))
        }
    }

    private var sftpCredentialRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Username")
                    .font(.system(size: 11)).foregroundStyle(Theme.dimText)
                    .frame(width: 90, alignment: .leading)
                TextField("sheepdrop", text: usernameBinding)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    .disabled(credentialsLocked)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Password")
                    .font(.system(size: 11)).foregroundStyle(Theme.dimText)
                    .frame(width: 90, alignment: .leading)
                SecureField(model.sftpServerPassword.isEmpty ? "set a password" : "••••••••", text: $sftpPasswordDraft)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    .disabled(credentialsLocked)
                Button("Save") {
                    model.setSFTPPassword(sftpPasswordDraft)
                    sftpPasswordDraft = ""
                }
                .controlSize(.small)
                .disabled(credentialsLocked || sftpPasswordDraft.isEmpty)
                Spacer()
            }
        }
    }

    /// The FTP server shares the SSH virtual login, so editing credentials
    /// while EITHER server is up would desync what a running server accepts
    /// from what the reach-URL shows.
    private var credentialsLocked: Bool {
        model.sftpServerRunning || model.ftpServerRunning
    }

    // MARK: - Step 3: the command

    private var selectedRunning: Bool {
        switch currentTransport {
        case .tftp: model.tftpServerRunning
        case .ssh: model.sftpServerRunning
        case .ftp: model.ftpServerRunning
        }
    }

    private var tftpStatus: String {
        if model.tftpServerRunning, let port = model.tftpActualPort {
            return "Listening · port \(port)"
        }
        return "Off"
    }

    private var sftpStatus: String {
        if model.sftpServerRunning, let port = model.sftpActualPort {
            return "Listening · port \(port)"
        }
        return "Off"
    }

    private var tftpRunningBinding: Binding<Bool> {
        Binding(get: { model.tftpServerRunning }, set: { model.setTFTPServer(on: $0) })
    }

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent))
            sectionTitle(title)
        }
    }



    private var sftpRunningBinding: Binding<Bool> {
        Binding(get: { model.sftpServerRunning }, set: { model.setSFTPServer(on: $0) })
    }

    private var usernameBinding: Binding<String> {
        Binding(get: { model.sftpUsername }, set: { model.setSFTPUsername($0) })
    }

    private var currentTransport: ServeTransport {
        ServeTransport(rawValue: transport) ?? .tftp
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Request log")
                Spacer()
                if !model.tftpLog.isEmpty {
                    Button("Clear") { model.tftpLog.removeAll() }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                }
            }
            if model.tftpLog.isEmpty {
                // Key off the selected server's own state, not TFTP's — on the
                // SFTP/FTP tab this used to say "Turn the server on" while that
                // server was already listening.
                Text(selectedRunning
                    ? "Waiting for requests — run the copy command on the device."
                    : "Turn the server on, then run the copy command on the device.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faintText)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.tftpLog.prefix(30)) { entry in
                        TFTPLogRow(entry: entry)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.content))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
    }

    /// Upload/download bar for the transfer a device is running (or just
    /// finished) on any built-in server. Sits directly under the request-log
    /// card. A completed transfer is KEPT here as a history row — it turns into
    /// a green "done" line and stays until the next transfer or server stop.
    /// Always present (like the Request Log card): shows an idle placeholder
    /// when nothing is transferring, and the live/held bar otherwise.
    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Transfer")
            if let t = model.activeServeTransfer {
                transferRow(t)
            } else {
                Text("No transfer yet — it appears here when a device pulls or pushes a file.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faintText)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .animation(.easeInOut(duration: 0.15), value: model.activeServeTransfer)
    }

    @ViewBuilder
    private func transferRow(_ t: ServeTransfer) -> some View {
        let fraction = t.total > 0 ? min(max(Double(t.done) / Double(t.total), 0), 1) : 0
        HStack(spacing: 6) {
            Image(systemName: barSymbol(t))
                .font(.system(size: 13))
                .foregroundStyle(barTint(t))
            Text(barLabel(t))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(barTint(t))
            Text(t.name)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(readout(t))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dimText)
        }
        switch t.state {
        case .active:
            if t.total > 0 {
                ProgressView(value: fraction).tint(Theme.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
        case .done:
            ProgressView(value: 1).tint(Theme.ok)
        case .failed:
            ProgressView(value: fraction).tint(Theme.err)
        }
    }

    private func barSymbol(_ t: ServeTransfer) -> String {
        switch t.state {
        case .active: return t.isUpload ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        case .done:   return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func barTint(_ t: ServeTransfer) -> Color {
        switch t.state {
        case .active: return Theme.accent
        case .done:   return Theme.ok
        case .failed: return Theme.err
        }
    }

    private func barLabel(_ t: ServeTransfer) -> String {
        switch t.state {
        case .active: return t.isUpload ? "Receiving" : "Sending"
        case .done:   return t.isUpload ? "Received" : "Sent"
        case .failed: return "Failed"
        }
    }

    private func readout(_ t: ServeTransfer) -> String {
        if t.total > 0 {
            let pct = Int((Double(t.done) / Double(t.total)) * 100)
            return "\(ByteFormat.string(t.done)) / \(ByteFormat.string(t.total)) · \(pct)%"
        }
        return ByteFormat.string(t.done)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.faintText)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.tftpRootPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.setTFTPRoot(url.path)
        }
    }
}

struct TFTPLogRow: View {
    let entry: TFTPLogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.time))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.disabledText)
            Text(entry.isWrite ? "WRQ" : "RRQ")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(entry.isWrite ? Theme.accent : Theme.warn)
                .frame(width: 30, alignment: .leading)
            Text(entry.filename)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(entry.failed ? Theme.err
                    : entry.detail == "started" ? Theme.faintText : Theme.ok)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairlineSoft.opacity(0.6)).frame(height: 0.5)
        }
    }
}
