import Foundation

/// Xcode itself, its build leftovers, simulators and simulator runtimes.
public struct XcodeProvider: Provider {
    public init() {}
    public let id = "xcode"
    public let title = "Xcode and simulators"
    public let section = Section.toolchains
    public let symbol = "hammer"

    static let folders: [(id: String, rel: String, title: String, risk: Risk)] = [
        ("deriveddata", "Library/Developer/Xcode/DerivedData", "Derived data", .regenerable),
        ("archives", "Library/Developer/Xcode/Archives", "Archives", .review),
        ("devicesupport", "Library/Developer/Xcode/iOS DeviceSupport", "iOS device support", .regenerable),
        ("simcaches", "Library/Developer/CoreSimulator/Caches", "Simulator caches", .regenerable),
    ]

    func xcodes(_ env: Environment) -> [(url: URL, version: String)] {
        env.applications.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name in
                guard name.hasSuffix(".app") else { return nil }
                let url = dir.appending(path: name)
                guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { return nil }
                return (url, info["CFBundleShortVersionString"] as? String ?? "")
            }
        }
    }

    public func isPresent(_ env: Environment) async -> Bool {
        !xcodes(env).isEmpty || Self.folders.contains { exists(env.path($0.rel)) } || exists(env.path("Library/Developer/CoreSimulator"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        let selected = await env.runner.run(["xcode-select", "-p"], timeout: .seconds(10)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for x in xcodes(env) {
            var badges = Set<Badge>()
            if !selected.isEmpty, (selected + "/").hasPrefix(x.url.path + "/") { badges.insert(.selectedByXcodeSelect) }
            if isAppRunning(x.url) { badges.insert(.running) }
            items.append(Item(id: "xcode.app.\(x.url.lastPathComponent)", title: "Xcode \(x.version)".trimmingCharacters(in: .whitespaces),
                              detail: x.url.path, paths: [x.url], bytes: 0, risk: .review, badges: badges))
        }
        for f in Self.folders where exists(env.path(f.rel)) {
            items.append(Item(id: "xcode.\(f.id)", title: f.title, detail: "~/\(f.rel)", paths: [env.path(f.rel)], bytes: 0, risk: f.risk))
        }

        let devices = await env.runner.run(["xcrun", "simctl", "list", "devices", "-j"], timeout: .seconds(30))
        if devices.ok, let data = devices.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, list) in byRuntime.sorted(by: { $0.key < $1.key }) {
                let os = runtime.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: " ", with: ".").replacingOccurrences(of: "iOS.", with: "iOS ") } ?? runtime
                for d in list {
                    guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                    var badges = Set<Badge>()
                    if d["state"] as? String == "Booted" { badges.insert(.running) }
                    items.append(Item(id: "xcode.sim.\(udid)", title: "\(name) simulator", detail: os,
                                      paths: [env.path("Library/Developer/CoreSimulator/Devices/\(udid)")], bytes: 0,
                                      risk: .regenerable, badges: badges))
                }
            }
        }
        items = await measured(items)

        let runtimes = await env.runner.run(["xcrun", "simctl", "runtime", "list", "-j"], timeout: .seconds(30))
        if runtimes.ok, let data = runtimes.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (key, r) in json.sorted(by: { $0.key < $1.key }) {
                let identifier = r["identifier"] as? String ?? key
                let platform = (r["platformIdentifier"] as? String ?? "").replacingOccurrences(of: "com.apple.platform.", with: "")
                let bytes = (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                items.append(Item(id: "xcode.runtime.\(identifier)", title: "Simulator runtime \(r["version"] as? String ?? "")",
                                  detail: platform, paths: [], bytes: bytes, risk: .regenerable))
            }
        }
        return items
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if item.badges.contains(.selectedByXcodeSelect) {
                if exists(env.system("Library/Developer/CommandLineTools")) {
                    plan.refusals.append(Refusal(itemID: id, reason: "Your developer tools point at this Xcode"))
                    plan.steps.append(Step("Point your developer tools at the Command Line Tools, then remove Xcode",
                                           .copyToTerminal("sudo xcode-select -s /Library/Developer/CommandLineTools"), itemID: id))
                } else {
                    plan.refusals.append(Refusal(itemID: id, reason: "Install the Command Line Tools first: xcode-select --install"))
                }
                continue
            }
            if let w = inUseWarning(item, noun: "simulator") { plan.warnings.append(w) }
            let kind: StepKind
            if id.hasPrefix("xcode.sim.") {
                kind = .command(argv: ["xcrun", "simctl", "delete", String(id.dropFirst("xcode.sim.".count))])
            } else if id.hasPrefix("xcode.runtime.") {
                kind = .command(argv: ["xcrun", "simctl", "runtime", "delete", String(id.dropFirst("xcode.runtime.".count))])
            } else {
                kind = .trash(item.paths)
            }
            plan.steps.append(Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: id))
        }
        return plan
    }
}
