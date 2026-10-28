import Foundation

/// Docker Desktop: its disk image, images and caches when it's running, and a
/// full uninstall that finds what the app leaves behind.
public struct DockerProvider: Provider {
    public init() {}
    public let id = "docker"
    public let title = "Docker"
    public let section = Section.containers
    public let symbol = "shippingbox"

    static let uninstall = "docker.uninstall"

    func app(_ env: Environment) -> URL? {
        env.applications.map { $0.appending(path: "Docker.app") }.first(where: exists)
    }

    func links(_ env: Environment) -> [URL] {
        let bin = env.system("usr/local/bin")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        return names.sorted().map { bin.appending(path: $0) }.filter { url in
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
            return dest.contains("/Docker.app/")
        }
    }

    public func isPresent(_ env: Environment) async -> Bool {
        app(env) != nil || exists(env.path(".docker")) || !links(env).isEmpty
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        guard await isPresent(env) else { return [] }
        var items: [Item] = [
            lockedItem(id: "docker.data", title: "Docker disk image", detail: "Images, containers and volumes",
                       paths: [env.path("Library/Containers/com.docker.docker")], risk: .review),
            lockedItem(id: "docker.group", title: "Docker shared data", detail: "group.com.docker",
                       paths: [env.path("Library/Group Containers/group.com.docker")], risk: .review),
        ]
        var plain: [Item] = []
        if exists(env.path(".docker")) {
            plain.append(Item(id: "docker.config", title: "Docker settings", detail: "~/.docker",
                              paths: [env.path(".docker")], bytes: 0, risk: .review))
        }
        if let app = app(env) {
            plain.append(Item(id: "docker.app", title: "Docker Desktop", detail: app.path, paths: [app], bytes: 0, risk: .review,
                              badges: isAppRunning(app) ? [.running] : []))
        }
        let links = links(env)
        if !links.isEmpty {
            plain.append(Item(id: "docker.links", title: "Docker command-line links",
                              detail: links.map(\.lastPathComponent).joined(separator: ", "), paths: links, bytes: 0, risk: .regenerable))
        }
        items += await measured(plain)

        if await env.runner.run(["docker", "info"], timeout: .seconds(15)).ok {
            items += await daemonItems(env)
        }
        return items
    }

    static let dfTypes: [String: (id: String, title: String, risk: Risk, argv: [String])] = [
        "Images": ("images", "Unused images", .regenerable, ["docker", "image", "prune", "-a", "-f"]),
        "Containers": ("containers", "Stopped containers", .review, ["docker", "container", "prune", "-f"]),
        "Local Volumes": ("volumes", "Unused volumes", .yourData, ["docker", "volume", "prune", "-a", "-f"]),
        "Build Cache": ("buildcache", "Build cache", .regenerable, ["docker", "builder", "prune", "-a", "-f"]),
    ]

    func daemonItems(_ env: Environment) async -> [Item] {
        let r = await env.runner.run(["docker", "system", "df", "--format", "{{json .}}"], timeout: .seconds(30))
        guard r.ok else { return [] }
        return r.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let type = row["Type"], let t = Self.dfTypes[type],
                  let bytes = parseDockerSize(row["Reclaimable"] ?? "") else { return nil }
            return Item(id: "docker.df.\(t.id)", title: t.title, detail: "\(row["TotalCount"] ?? "?") total, \(row["Active"] ?? "?") in use",
                        paths: [], bytes: bytes, risk: t.risk)
        }
    }

    public func extraActions(_ items: [Item]) -> [ProviderAction] {
        [ProviderAction(id: Self.uninstall, title: "Uninstall Docker completely", itemIDs: items.map(\.id))]
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        if ids.contains(Self.uninstall) { return uninstallPlan(items, env: env) }
        var plan = planEach(ids, items: items, noun: "Docker") { item in
            if item.id.hasPrefix("docker.df."), let t = Self.dfTypes.values.first(where: { "docker.df.\($0.id)" == item.id }) {
                return [Step("Remove \(item.title.lowercased())", .command(argv: t.argv), bytes: item.bytes, itemID: item.id)]
            }
            return trashSteps(item, env: env)
        }
        if ids.contains("docker.df.volumes") {
            plan.dangers.append("Unused volumes hold the data of containers that aren't running, such as local databases. Docker deletes them for good.")
        }
        return plan
    }

    func trashSteps(_ item: Item, env: Environment) -> [Step] {
        if item.id == "docker.links", !FileManager.default.isWritableFile(atPath: env.system("usr/local/bin").path) {
            return [Step("Remove Docker's command-line links", .copyToTerminal("sudo rm " + item.paths.map { shellQuote($0.path) }.joined(separator: " ")), itemID: item.id)]
        }
        return [Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id)]
    }

    func uninstallPlan(_ items: [Item], env: Environment) -> Plan {
        var plan = Plan(dangers: ["This removes Docker Desktop with all its images, containers and volumes."])
        if items.contains(where: { $0.id == "docker.app" && $0.badges.contains(.running) }) {
            plan.dangers.append("Docker Desktop is running. Quit it first.")
        }
        let candidates = [app(env), env.path(".Trash/Docker.app")].compactMap { $0 }
        if let uninstaller = candidates.map({ $0.appending(path: "Contents/MacOS/uninstall") }).first(where: exists) {
            plan.steps.append(Step("Run Docker's own uninstaller", .command(argv: [uninstaller.path])))
        }
        for id in ["docker.data", "docker.group", "docker.config", "docker.app", "docker.links"] {
            if let item = items.first(where: { $0.id == id }) { plan.steps += trashSteps(item, env: env) }
        }
        let system = ["Library/PrivilegedHelperTools", "Library/LaunchDaemons"].flatMap { rel -> [URL] in
            let dir = env.system(rel)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.hasPrefix("com.docker.") }.sorted().map { dir.appending(path: $0) }
        }
        if !system.isEmpty {
            plan.steps.append(Step("Remove Docker's system helpers (needs your password)",
                                   .copyToTerminal("sudo rm -f " + system.map { shellQuote($0.path) }.joined(separator: " "))))
        }
        return plan
    }
}

/// Docker's sizes: "2.1GB", "500MB (50%)", "1.5kB". Docker counts in 1000s.
func parseDockerSize(_ s: String) -> Int64? {
    guard let m = s.firstMatch(of: /^\s*([\d.]+)\s*([kKMGT]?B)/), let n = Double(m.1) else { return nil }
    let powers: [String: Double] = ["B": 0, "kB": 1, "KB": 1, "MB": 2, "GB": 3, "TB": 4]
    return Int64((n * pow(1000, powers[String(m.2)] ?? 0)).rounded())
}
