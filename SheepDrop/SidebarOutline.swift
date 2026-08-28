import AppKit
import SwiftUI

/// The sidebar's Recent + groups + hosts list, as a real NSOutlineView.
///
/// SwiftUI `.draggable`/`.dropDestination` could never feel right: AppKit
/// animates the drag image back to the drag's origin on every drop and
/// SwiftUI exposes no way to stop it, so a dropped row always drifted, and
/// the `isTargeted` highlight animated too. NSOutlineView owns the whole
/// gesture — it decides click vs drag by the system threshold, opens the
/// insertion gap itself, and the row is simply *there* on mouse-up. Same
/// approach (and much of the same code shape) as SheepTerm's SidebarOutline.
///
/// Cells are `NSHostingView`s of small gesture-less SwiftUI content views, so
/// the row styling stays identical to the rest of the app; the outline, not
/// SwiftUI, handles click/drag/context.

enum SidebarRowKind { case section, group, host }

final class SidebarItem: NSObject {
    let id: String
    let kind: SidebarRowKind
    var title = ""
    var group: HostGroup?
    var host: HostEntry?
    var isRecent = false
    var children: [SidebarItem] = []

    init(id: String, kind: SidebarRowKind) {
        self.id = id
        self.kind = kind
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        (object as? SidebarItem)?.id == id
    }
    nonisolated override var hash: Int { id.hashValue }
    var isExpandable: Bool { kind == .section || kind == .group }
}

struct SidebarOutline: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let recents: [HostEntry]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = OutlineView()
        outline.coordinator = context.coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.style = .plain
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 0
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.click(_:))
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        context.coordinator.outline = outline
        context.coordinator.rebuild()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.recents = recents
        context.coordinator.rebuild()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: AppModel
        var recents: [HostEntry] = []
        weak var outline: NSOutlineView?
        private var roots: [SidebarItem] = []
        private var signature = ""

        init(model: AppModel) { self.model = model }

        /// Rebuild the item tree only when the underlying data actually
        /// changed — a reload on every SwiftUI update would fight the drag.
        func rebuild() {
            let newSignature = makeSignature()
            guard newSignature != signature else { return }
            signature = newSignature

            var items: [SidebarItem] = []
            let visibleRecents = recentsToShow()
            if !visibleRecents.isEmpty {
                let section = SidebarItem(id: "section-recent", kind: .section)
                section.title = "Recent"
                section.children = visibleRecents.enumerated().map { index, host in
                    let item = SidebarItem(id: "recent-\(index)-\(host.id)", kind: .host)
                    item.host = host
                    item.isRecent = true
                    return item
                }
                items.append(section)
            }
            for group in model.groups {
                let groupItem = SidebarItem(id: "group-\(group.id)", kind: .group)
                groupItem.group = group
                groupItem.title = group.name
                groupItem.children = group.hosts.map { host in
                    let item = SidebarItem(id: "host-\(host.id)", kind: .host)
                    item.host = host
                    item.group = group
                    return item
                }
                items.append(groupItem)
            }
            roots = items
            outline?.reloadData()
            for root in roots { outline?.expandItem(root) }
        }

        private func makeSignature() -> String {
            let g = model.groups.map { grp in
                "\(grp.id)|\(grp.name)|" + grp.hosts.map { "\($0.id):\($0.displayName):\($0.proto.rawValue)" }.joined(separator: ",")
            }.joined(separator: ";")
            let r = recentsToShow().map { "\($0.id)" }.joined(separator: ",")
            return g + "##" + r
        }

        private func recentsToShow() -> [HostEntry] {
            let saved = Set(model.groups.flatMap(\.hosts).map(key))
            return Array(recents.lazy.filter { !saved.contains(self.key($0)) }.prefix(3))
        }

        private func key(_ h: HostEntry) -> String {
            "\(h.address)|\(h.port)|\(h.username)|\(h.proto.rawValue)"
        }

        // MARK: Data source

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarItem)?.children.count ?? roots.count
        }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? SidebarItem)?.children[index] ?? roots[index]
        }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarItem)?.isExpandable ?? false
        }

        // MARK: Delegate

        func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            switch (item as? SidebarItem)?.kind {
            case .section: return 26
            case .group: return 26
            default: return 42
            }
        }

        func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = ov.makeView(withIdentifier: .init("row"), owner: self) as? RowView
                ?? { let r = RowView(); r.identifier = .init("row"); return r }()
            row.selectionHighlightStyle = (item as? SidebarItem)?.kind == .host ? .regular : .none
            return row
        }

        func outlineView(_ ov: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarItem else { return nil }
            let id = NSUserInterfaceItemIdentifier(node.kind == .host ? "host" : "label")
            let host = ov.makeView(withIdentifier: id, owner: self) as? PassthroughHostingView
            let content: AnyView
            switch node.kind {
            case .section:
                content = AnyView(OutlineSectionLabel(text: node.title))
            case .group:
                content = AnyView(OutlineGroupLabel(name: node.title, count: node.group?.hosts.count ?? 0))
            case .host:
                content = AnyView(OutlineHostContent(host: node.host!, isRecent: node.isRecent))
            }
            if let host {
                host.rootView = content
                return host
            }
            let view = PassthroughHostingView(rootView: content)
            view.identifier = id
            return view
        }

        func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarItem)?.kind == .host
        }
        func outlineView(_ ov: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            false   // no disclosure triangles — sections/groups stay open
        }
        func outlineView(_ ov: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

        // MARK: Click / context

        @objc func click(_ sender: OutlineView) {
            guard sender.clickedRow >= 0,
                  let node = sender.item(atRow: sender.clickedRow) as? SidebarItem,
                  node.kind == .host, let host = node.host else { return }
            connect(host)
        }

        private func connect(_ host: HostEntry) {
            model.mainPane = .connection
            if let existing = model.tabs.first(where: {
                $0.host.address == host.address && $0.host.port == host.port
                    && $0.host.username == host.username && $0.host.proto == host.proto
            }) {
                model.selectedTabID = existing.id
            } else {
                model.openTab(for: host)
            }
        }

        func contextMenu(for node: SidebarItem) -> NSMenu {
            let menu = NSMenu()
            switch node.kind {
            case .host where node.isRecent:
                if let host = node.host {
                    menu.addItem(MenuAction(title: "Connect") { [self] in connect(host) })
                    menu.addItem(.separator())
                    if !model.groups.isEmpty {
                        let sub = NSMenu()
                        for group in model.groups {
                            sub.addItem(MenuAction(title: group.name) { [self] in
                                model.addHost(host, toGroup: group.id); model.removeRecent(host)
                            })
                        }
                        let save = NSMenuItem(title: "Save to Group", action: nil, keyEquivalent: "")
                        save.submenu = sub
                        menu.addItem(save)
                    }
                    menu.addItem(MenuAction(title: "Remove from Recents") { [self] in model.removeRecent(host) })
                }
            case .host:
                if let host = node.host {
                    menu.addItem(MenuAction(title: "Connect") { [self] in connect(host) })
                    menu.addItem(.separator())
                    let current = model.groupID(of: host)
                    let others = model.groups.filter { $0.id != current }
                    if !others.isEmpty {
                        let sub = NSMenu()
                        for group in others {
                            sub.addItem(MenuAction(title: group.name) { [self] in model.moveHost(host, toGroup: group.id) })
                        }
                        let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
                        move.submenu = sub
                        menu.addItem(move)
                    }
                    menu.addItem(MenuAction(title: "Delete Host") { [self] in model.deleteHost(host) })
                }
            case .group:
                if let group = node.group {
                    menu.addItem(MenuAction(title: "New Host in “\(group.name)”") { [self] in
                        model.pendingGroupID = group.id; model.showQuickConnect = true
                    })
                    menu.addItem(MenuAction(title: "Delete Group") { [self] in model.deleteGroup(group.id) })
                }
            case .section:
                break
            }
            return menu
        }

        // MARK: Drag & drop  (the whole point)

        func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarItem else { return nil }
            switch node.kind {
            case .group: return node.group.map { "group:\($0.id.uuidString)" as NSString }
            case .host where !node.isRecent: return node.host.map { "host:\($0.id.uuidString)" as NSString }
            default: return nil
            }
        }

        private func payload(_ info: NSDraggingInfo) -> (isGroup: Bool, id: UUID)? {
            guard let text = info.draggingPasteboard.string(forType: .string) else { return nil }
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            return (parts[0] == "group", id)
        }

        func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let payload = payload(info) else { return [] }
            let groupRoots = roots.filter { $0.kind == .group }
            let firstGroupRow = roots.firstIndex { $0.kind == .group } ?? 0
            if payload.isGroup {
                // Groups reorder among the root group items only.
                if item == nil {
                    let target = index == NSOutlineViewDropOnItemIndex ? roots.count : max(index, firstGroupRow)
                    ov.setDropItem(nil, dropChildIndex: target)
                    return .move
                }
                if let node = item as? SidebarItem, node.kind == .group,
                   let pos = roots.firstIndex(of: node) {
                    ov.setDropItem(nil, dropChildIndex: index == NSOutlineViewDropOnItemIndex ? pos : pos + 1)
                    return .move
                }
                _ = groupRoots
                return []
            }
            // Host: must land inside a group.
            guard let groupNode = groupNode(for: item) else { return [] }
            var target = index
            if let node = item as? SidebarItem, node.kind == .host {
                target = groupNode.children.firstIndex(of: node) ?? groupNode.children.count
            } else if index == NSOutlineViewDropOnItemIndex {
                target = groupNode.children.count
            }
            ov.setDropItem(groupNode, dropChildIndex: max(0, min(target, groupNode.children.count)))
            return .move
        }

        private func groupNode(for item: Any?) -> SidebarItem? {
            guard let node = item as? SidebarItem else { return nil }
            if node.kind == .group { return node }
            if node.kind == .host, !node.isRecent, let gid = node.group?.id {
                return roots.first { $0.kind == .group && $0.group?.id == gid }
            }
            return nil
        }

        func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let payload = payload(info) else { return false }
            if payload.isGroup {
                // childIndex is among ALL roots (Recent section may be root 0);
                // translate to a "before which group" target.
                let target = roots.indices.contains(index) ? roots[index] : nil
                model.dropGroup(payload.id, before: target?.group?.id)
            } else {
                guard let groupNode = (item as? SidebarItem)?.group ?? groupNode(for: item)?.group else { return false }
                model.dropHost(payload.id, intoGroup: groupNode.id, at: max(0, index))
            }
            return true
        }
    }
}

/// Outline view: adds a per-row context menu (AppKit leaves this to us).
final class OutlineView: NSOutlineView {
    weak var coordinator: SidebarOutline.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let item = item(atRow: row) as? SidebarItem else { return nil }
        return coordinator?.contextMenu(for: item)
    }
}

/// Accent pill selection, drawn here so it isn't the washed-out unfocused grey
/// (the sidebar hands focus back to content on every click).
final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 8, dy: 2)
        NSColor(Theme.selectedRow).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 7, yRadius: 7).fill()
    }
}

/// NSHostingView whose hitTest returns nil, so ALL mouse events (click, drag)
/// belong to the enclosing NSOutlineView — that is what makes a click land on
/// the first try and a drag start without a hitch. The SwiftUI content is
/// purely visual; the outline drives every interaction. (SheepTerm's
/// SidebarHostCell does the same.)
private final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @available(*, unavailable) @MainActor required init(rootView: AnyView, sizingOptions: NSHostingSizingOptions) {
        fatalError()
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    // NSMenuItem's designated inits are nonisolated; override explicitly to
    // silence the isolation-mismatch (same trick as SheepTerm's MenuAction).
    nonisolated override init(title: String, action: Selector?, keyEquivalent: String) {
        fatalError("use init(title:run:)")
    }
    nonisolated required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - Cell content (gesture-less; the outline drives interaction)

private struct OutlineSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.faintText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }
}

private struct OutlineGroupLabel: View {
    let name: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(Theme.faintText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, 4)
    }
}

private struct OutlineHostContent: View {
    let host: HostEntry
    let isRecent: Bool
    @ObservedObject private var model = AppModel.shared

    private var isConnected: Bool {
        model.tabs.contains {
            $0.host.address == host.address && $0.host.proto == host.proto
                && $0.status != .disconnected
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(isConnected ? Theme.ok : Theme.protoColor(host.proto))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(host.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faintText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(host.proto.label)
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.3)
                .foregroundStyle(Theme.protoColor(host.proto))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.protoColor(host.proto).opacity(0.12)))
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var subtitle: String? {
        let hasName = !host.name.isEmpty && host.name != host.address
        let portPart = host.port == host.proto.defaultPort ? "" : ":\(host.port)"
        if hasName { return "\(host.address)\(portPart)" }
        if host.proto == .tftp { return portPart.isEmpty ? nil : "port \(host.port)" }
        guard !host.username.isEmpty else { return portPart.isEmpty ? nil : "port \(host.port)" }
        return "\(host.username)@\(host.address)\(portPart)"
    }
}
