import Foundation

/// Loads and saves host groups + recents under Application Support/SheepDrop.
/// Deliberately separate from SheepTerm's store (own folder, own Keychain
/// service later). Every write copies the previous file to .bak first —
/// the full merge-on-save-by-mtime scheme from SheepTerm can be ported once
/// two writers become a real possibility.
@MainActor
final class HostStore {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SheepDrop", isDirectory: true)

    private var hostsURL: URL { Self.directory.appendingPathComponent("hosts.json") }
    private var recentsURL: URL { Self.directory.appendingPathComponent("recents.json") }

    static let maxRecents = 20

    func loadGroups() -> [HostGroup] {
        guard let data = try? Data(contentsOf: hostsURL),
              let groups = try? JSONDecoder().decode([HostGroup].self, from: data)
        else {
            return [HostGroup(name: "My Devices")]
        }
        return groups
    }

    func loadRecents() -> [HostEntry] {
        guard let data = try? Data(contentsOf: recentsURL),
              let recents = try? JSONDecoder().decode([HostEntry].self, from: data)
        else {
            return []
        }
        return recents
    }

    func saveGroups(_ groups: [HostGroup]) {
        write(groups, to: hostsURL)
    }

    func saveRecents(_ recents: [HostEntry]) {
        write(Array(recents.prefix(Self.maxRecents)), to: recentsURL)
    }

    private func write(_ value: some Encodable, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        try? data.write(to: url, options: .atomic)
    }
}
