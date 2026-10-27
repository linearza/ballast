import Foundation

/// Other developer data that grows quietly. Shown for insight; moved to the Trash on request.
public struct OtherDevDataProvider: Provider {
    public init() {}
    public let id = "otherDevData"
    public let title = "Other dev data"
    public let section = Section.other
    public let symbol = "ellipsis.circle"

    static let entries: [(id: String, title: String, rel: String, hint: String)] = [
        ("cursorWorkspaces", "Cursor workspace storage", "Library/Application Support/Cursor/User/workspaceStorage", "Per-project editor state; rebuilt when you reopen a project"),
        ("vscodeWorkspaces", "VS Code workspace storage", "Library/Application Support/Code/User/workspaceStorage", "Per-project editor state; rebuilt when you reopen a project"),
        ("claudeVMs", "Claude VM bundles", "Library/Application Support/Claude/vm_bundles", "Prefer clearing from inside Claude"),
        ("puppeteer", "Puppeteer browsers", ".cache/puppeteer", "Downloaded again on next install"),
        ("devtoolsMCP", "Chrome DevTools MCP cache", ".cache/chrome-devtools-mcp", "Downloaded again when needed"),
    ]

    func entries(_ env: Environment) -> [(id: String, title: String, url: URL, hint: String)] {
        let runners = ((try? FileManager.default.contentsOfDirectory(atPath: env.home.path)) ?? [])
            .filter { $0.hasPrefix("actions-runner") }.sorted()
            .map { (id: "other.\($0)", title: "GitHub Actions runner (\($0))", url: env.path($0), hint: "Unregister the runner first if it's still in use") }
        return runners + Self.entries.map { (id: "other.\($0.id)", title: $0.title, url: env.path($0.rel), hint: $0.hint) }.filter { exists($0.url) }
    }

    public func isPresent(_ env: Environment) async -> Bool { !entries(env).isEmpty }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        await measured(entries(env).map { Item(id: $0.id, title: $0.title, detail: $0.hint, paths: [$0.url], bytes: 0, risk: .review) })
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        planEach(ids, items: items, noun: "folder") { item in
            [Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id)]
        }
    }
}
