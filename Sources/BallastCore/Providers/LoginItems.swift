import Foundation

/// LaunchAgents in ~/Library/LaunchAgents whose program no longer exists.
public struct LoginItemsProvider: Provider {
    public init() {}
    public let id = "loginItems"
    public let title = "Leftover login items"
    public let section = Section.other
    public let symbol = "power"

    public func isPresent(_ env: Environment) async -> Bool { exists(env.path("Library/LaunchAgents")) }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        let dir = env.path("Library/LaunchAgents")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".plist") }.sorted()
        var items: [Item] = []
        for name in names {
            let url = dir.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"), !exists(URL(filePath: program)), !onUnmountedVolume(program) else { continue }
            let label = plist["Label"] as? String ?? (name as NSString).deletingPathExtension
            let detail = label.hasPrefix("homebrew.mxcl.")
                ? "Homebrew service for \(label.dropFirst("homebrew.mxcl.".count)), which is no longer installed"
                : "Starts \(program), which no longer exists"
            let size = await measure([url])
            items.append(Item(id: "login.\(label)", title: label, detail: detail, paths: [url], bytes: size.bytes, risk: .regenerable))
        }
        return items
    }

    /// `/Volumes/<disk>/…` when that disk isn't plugged in: the program may be fine, just not here right now.
    func onUnmountedVolume(_ program: String) -> Bool {
        let parts = program.split(separator: "/")
        guard parts.count > 1, parts[0] == "Volumes" else { return false }
        return !exists(URL(filePath: "/Volumes/\(parts[1])"))
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        planEach(ids, items: items, noun: "login item") { item in
            guard let plist = item.paths.first else { return [] }
            return [Step("Stop \(item.title)", .unloadLoginItem(label: item.title, plist: plist), itemID: item.id),
                    Step("Move its file to the Trash", .trash([plist]), bytes: item.bytes, itemID: item.id)]
        }
    }
}
