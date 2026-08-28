import SwiftUI

/// ⌘T sheet: protocol, address, credentials, optional name, and where to
/// save it — an existing group, a new group, or nowhere. Passwords are
/// collected on connect (Keychain), not here.
struct QuickConnectSheet: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var username = "admin"
    @State private var portText = ""
    @State private var proto: TransferProtocolKind = .sftp
    /// Sentinel raw values for the save picker.
    @State private var saveTarget = "none"
    @State private var newGroupName = ""

    private static let noneTag = "none"
    private static let newGroupTag = "__new__"

    init() {
        if let pending = AppModel.shared.pendingGroupID {
            _saveTarget = State(initialValue: pending.uuidString)
            AppModel.shared.pendingGroupID = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Connection")
                .font(.system(size: 15, weight: .medium))

            Picker("Protocol", selection: $proto) {
                ForEach(TransferProtocolKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Host or IP address", text: $address)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(proto == .tftp)
                    .opacity(proto == .tftp ? 0.4 : 1)
                TextField("Port \(proto.defaultPort)", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Text("Save to")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Picker("", selection: $saveTarget) {
                    Text("Don't save").tag(Self.noneTag)
                    ForEach(model.groups) { group in
                        Text(group.name).tag(group.id.uuidString)
                    }
                    Divider()
                    Text("New group…").tag(Self.newGroupTag)
                }
                .labelsHidden()
                if saveTarget == Self.newGroupTag {
                    TextField("Group name", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        // Clamp to the valid TCP/UDP range — an out-of-range port used to trap
        // in UInt16() deep inside the FTP worker.
        let typedPort = Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil }
        let host = HostEntry(
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            port: typedPort ?? proto.defaultPort,
            username: proto == .tftp ? "" : username.trimmingCharacters(in: .whitespaces),
            proto: proto
        )

        switch saveTarget {
        case Self.noneTag:
            break
        case Self.newGroupTag:
            let groupName = newGroupName.trimmingCharacters(in: .whitespaces)
            if !groupName.isEmpty {
                let id = model.addGroup(named: groupName)
                model.addHost(host, toGroup: id)
            }
        default:
            if let id = UUID(uuidString: saveTarget) {
                model.addHost(host, toGroup: id)
            }
        }

        model.mainPane = .connection
        // Reuse an already-open tab to the same host instead of spawning a
        // second live connection (matches the sidebar's connect behaviour).
        if let existing = model.tabs.first(where: {
            $0.host.address == host.address && $0.host.port == host.port
                && $0.host.username == host.username && $0.host.proto == host.proto
        }) {
            model.selectedTabID = existing.id
        } else {
            model.openTab(for: host)
        }
        dismiss()
    }
}
