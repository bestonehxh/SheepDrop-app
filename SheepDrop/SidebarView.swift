import SwiftUI

/// Design v2 sidebar: traffic-light row on top, then host groups
/// (protocol-colored dot + name + address + protocol badge), the Activity
/// section (Transfers / Serve), Recent, and an accent New Connection button.
struct SidebarView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var renamingGroup: HostGroup?
    @State private var renameText = ""
    @State private var creatingGroup = false
    @State private var newGroupText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Traffic-light row (the sidebar owns the titlebar area).
            HStack {
                Spacer()
            }
            .frame(height: model.isFullScreen ? 12 : 52)

            // The one concept the whole app hinges on: are we the client
            // (reach out to a device) or the server (a device reaches in)?
            // Two equal buttons make the direction unmistakable.
            modeSwitch
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // The sidebar body belongs to whichever mode is active: the host
            // library in Connect, a short server summary in Serve. This is why
            // "New Connection" (a client action) no longer shows in Serve.
            if isServerMode {
                serverSidebar
            } else {
                connectSidebar
            }

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
                if isServerMode {
                    serverBottomBar
                } else {
                HStack(spacing: 8) {
                    Button {
                        model.showQuickConnect = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("New Connection")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    Button {
                        newGroupText = ""
                        creatingGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.dimText)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.control))
                    }
                    .buttonStyle(.plain)
                    .help("New group")
                }
                .padding(10)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar, ignoresSafeAreaEdges: [])
        .alert("Rename group", isPresented: renameBinding) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Rename") {
                if let group = renamingGroup {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.renameGroup(group.id, to: name) }
                }
                renamingGroup = nil
            }
        }
        .alert("New group", isPresented: $creatingGroup) {
            TextField("Group name", text: $newGroupText)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newGroupText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.addGroup(named: name) }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })
    }

    // MARK: - Mode-specific sidebar bodies

    private var isServerMode: Bool { model.mainPane == .serve }

    /// Client mode: the saved-host library + Transfers.
    private var connectSidebar: some View {
        VStack(spacing: 0) {
            // Recent + groups + hosts live in a real NSOutlineView so drag
            // reorder is native (no SwiftUI drop animation / drift).
            SidebarOutline(model: model, recents: model.recents)
            Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
            ActivityRow(
                icon: "arrow.left.arrow.right",
                title: "Transfers",
                isSelected: model.mainPane == .transfers,
                trailing: { AnyView(TransfersBadge()) }
            ) {
                model.mainPane = .transfers
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// Server mode: no host list (irrelevant when a device connects in) — a
    /// compact status of the two servers instead.
    private var serverSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Servers")
            serverStatusRow(name: "TFTP", running: model.tftpServerRunning,
                            detail: model.tftpServerRunning ? "port \(model.tftpActualPort.map(String.init) ?? "69")" : "off")
            serverStatusRow(name: "SFTP / SCP", running: model.sftpServerRunning,
                            detail: model.sftpServerRunning ? "port \(model.sftpActualPort.map(String.init) ?? "2222")" : "off")
            serverStatusRow(name: "FTP", running: model.ftpServerRunning,
                            detail: model.ftpServerRunning ? "port \(model.ftpActualPort.map(String.init) ?? "21")" : "off")
            Text("Configure and toggle each server in the panel on the right.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faintText)
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serverStatusRow(name: String, running: Bool, detail: String) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(running ? Theme.ok : Theme.faintText)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 13, weight: running ? .semibold : .regular))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(running ? Theme.ok : Theme.faintText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var serverBottomBar: some View {
        Text("SheepDrop is serving files to devices that connect in.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.faintText)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private var modeSwitch: some View {
        HStack(spacing: 6) {
            modeButton(
                title: "Connect",
                subtitle: "reach a device",
                icon: "arrow.up.right",
                active: !isServerMode
            ) {
                // Always return to the file view — not only from Serve. The
                // Transfers pane also counts as "Connect" (the button stays
                // highlighted there), so without this an open Transfers view
                // had no one-click way back to the connection.
                model.mainPane = .connection
            }
            modeButton(
                title: "Serve",
                subtitle: "device reaches in",
                icon: "square.and.arrow.down",
                active: isServerMode
            ) {
                model.mainPane = .serve
            }
        }
    }

    private func modeButton(title: String, subtitle: String, icon: String,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(active ? .white : Theme.text2)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(active ? Color.white.opacity(0.85) : Theme.faintText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.accent : Theme.control))
        }
        .buttonStyle(.plain)
    }

    // Group headers, host rows, and their drag/drop now live in
    // SidebarOutline (a real NSOutlineView) — the SwiftUI versions were
    // removed with the outline swap. `sectionHeader` stays: the mode switch's
    // "Servers" list and the outline's own labels reuse the look.
    private func sectionHeader(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.faintText)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}


struct ActivityRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var isSelected = false
    var trailing: () -> AnyView = { AnyView(EmptyView()) }
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dimText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faintText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.selectedRow : hovering ? Theme.hover : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

struct TransfersBadge: View {
    @ObservedObject private var model = AppModel.shared

    private var activeCount: Int {
        model.tabs.compactMap(\.sftp).filter { $0.transfer != nil }.count
    }

    var body: some View {
        if activeCount > 0 {
            Text("\(activeCount)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.accent))
        }
    }
}
