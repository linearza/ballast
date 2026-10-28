import Foundation

/// What `brew` says about services and installed formulae, read once per scan.
struct BrewState: Sendable {
    var started: Set<String> = []
    var formulae: Set<String> = []

    static func read(_ env: Environment) async -> BrewState {
        var state = BrewState()
        let services = await env.runner.run(["brew", "services", "list", "--json"])
        if services.ok, let data = services.stdout.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            state.started = Set(list.compactMap { $0["status"] as? String == "started" ? $0["name"] as? String : nil })
        }
        let formulae = await env.runner.run(["brew", "list", "--formula"])
        if formulae.ok {
            state.formulae = Set(formulae.stdout.split(whereSeparator: \.isNewline).map(String.init))
        }
        return state
    }
}

/// "approximately 1.2GB" → bytes. Homebrew counts in 1024s.
func parseBrewFreed(_ text: String) -> Int64? {
    guard let m = text.firstMatch(of: /would free approximately ([\d.]+)\s*([KMGT]?B)/) else { return nil }
    guard let n = Double(m.1) else { return nil }
    let powers: [String: Double] = ["B": 0, "KB": 1, "MB": 2, "GB": 3, "TB": 4]
    let power = powers[String(m.2)] ?? 0
    return Int64(n * pow(1024, power))
}

/// Old versions, the download cache, unused dependencies and big logs.
public struct HomebrewProvider: Provider {
    public init() {}
    public let id = "homebrew"
    public let title = "Homebrew"
    public let section = Section.toolchains
    public let symbol = "mug"

    static let bigLog: Int64 = 10_000_000

    public func isPresent(_ env: Environment) async -> Bool { env.brewPrefix != nil }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        guard let prefix = env.brewPrefix else { return [] }
        let state = await BrewState.read(env)
        var items: [Item] = []

        let cleanup = await env.runner.run(["brew", "cleanup", "--prune=all", "-n"], timeout: .seconds(120))
        if let freed = parseBrewFreed(cleanup.stdout), freed > 0 {
            items.append(Item(id: "brew.cleanup", title: "Old versions and downloads", detail: "brew cleanup --prune=all",
                              paths: [], bytes: freed, risk: .regenerable))
        }

        let auto = await env.runner.run(["brew", "autoremove", "-n"], timeout: .seconds(120))
        let unneeded = auto.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("==>") && !$0.isEmpty }
        if auto.ok, !unneeded.isEmpty {
            let cellars = unneeded.map { prefix.appending(path: "Cellar/\($0)") }
            let m = await measure(cellars)
            items.append(Item(id: "brew.autoremove", title: "Unused dependencies", detail: unneeded.joined(separator: ", "),
                              paths: cellars, bytes: m.bytes, sizeIsPartial: m.partial, risk: .review))
        }

        let logDir = prefix.appending(path: "var/log")
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? []
        for name in logs.sorted() {
            let url = logDir.appending(path: name)
            let m = await measure([url])
            guard m.bytes >= Self.bigLog else { continue }
            let service = serviceFor(log: name, started: state.started)
            items.append(Item(id: "brew.log.\(name)", title: name,
                              detail: service.map { "\($0) is running: emptied in place" } ?? "Service log",
                              paths: [url], bytes: m.bytes, risk: .regenerable))
        }
        return items
    }

    func serviceFor(log name: String, started: Set<String>) -> String? {
        let base = (name as NSString).deletingPathExtension
        return started.first { base == $0 || base.hasPrefix("\($0)-") || base.hasPrefix("\($0).") }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let state = await BrewState.read(env)
        return planEach(ids, items: items, noun: "Homebrew") { item in
            switch item.id {
            case "brew.cleanup":
                return [Step("Remove old versions and downloads", .command(argv: ["brew", "cleanup", "--prune=all"]), bytes: item.bytes, itemID: item.id)]
            case "brew.autoremove":
                return [Step("Uninstall unused dependencies", .command(argv: ["brew", "autoremove"]), bytes: item.bytes, itemID: item.id)]
            default:
                guard let url = item.paths.first else { return [] }
                if serviceFor(log: item.title, started: state.started) != nil {
                    return [Step("Empty \(item.title)", .truncate(url), bytes: item.bytes, itemID: item.id)]
                }
                return [Step("Move \(item.title) to the Trash", .trash([url]), bytes: item.bytes, itemID: item.id)]
            }
        }
    }
}

/// Database folders Homebrew services keep in `var/`, including ones left
/// behind after the formula was uninstalled, and the data of Postgres.app and DBngin.
public struct DatabasesProvider: Provider {
    public init() {}
    public let id = "databases"
    public let title = "Local databases"
    public let section = Section.databases
    public let symbol = "cylinder.split.1x2"

    static let prefixes = ["postgres", "mysql", "mariadb", "redis", "mongodb", "elasticsearch", "opensearch", "cassandra",
                           "influxdb", "couchdb", "rabbitmq", "minio", "clickhouse", "valkey", "neo4j"]
    static let postgresApp = "Library/Application Support/Postgres"
    static let dbngin = "Users/Shared/DBngin"

    public func isPresent(_ env: Environment) async -> Bool {
        env.brewPrefix != nil || exists(env.path(Self.postgresApp)) || exists(env.system(Self.dbngin))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        // Postgres.app keeps one data folder per major version: var-16.
        for name in subfolders(env.path(Self.postgresApp)) where name.hasPrefix("var-") {
            let dir = env.path("\(Self.postgresApp)/\(name)")
            let live = hasLivePidFile(dir)
            items.append(Item(id: "db.postgresapp.\(name)", title: "Postgres.app \(name.dropFirst(4))", detail: live ? "Running" : "Stopped",
                              paths: [dir], bytes: 0, risk: .yourData, badges: live ? [.running] : []))
        }
        // DBngin: <engine>/<version>, with the server's files and its data.
        let dbngin = env.system(Self.dbngin)
        for engine in subfolders(dbngin) {
            for version in subfolders(dbngin.appending(path: engine)) {
                let dir = dbngin.appending(path: "\(engine)/\(version)")
                let live = hasLivePidFile(dir) || hasLivePidFile(dir.appending(path: "data"))
                items.append(Item(id: "db.dbngin.\(engine).\(version)", title: "\(engine) \(version)", detail: "DBngin · \(live ? "Running" : "Stopped")",
                                  paths: [dir], bytes: 0, risk: .yourData, badges: live ? [.running] : []))
            }
        }
        guard let prefix = env.brewPrefix else { return await measured(items) }
        let state = await BrewState.read(env)
        for name in subfolders(prefix.appending(path: "var")) where Self.prefixes.contains(where: name.hasPrefix) {
            var badges = Set<Badge>()
            let formula = matchingFormula(name, in: state.formulae)
            if formula == nil { badges.insert(.orphaned) }
            let service = state.started.first { $0 == name || $0 == formula }
            let live = service != nil || hasLivePidFile(prefix.appending(path: "var/\(name)"))
            if live { badges.insert(.running) }
            var detail = formula == nil ? "\(name) is no longer installed" : (live ? "Running" : "Stopped")
            if let service, name.hasPrefix("postgres"), let top = await largestDatabases(env, prefix: prefix, formula: service) {
                detail += " · " + top
            }
            items.append(Item(id: "db.\(name)", title: name, detail: detail, paths: [prefix.appending(path: "var/\(name)")],
                              bytes: 0, risk: .yourData, badges: badges))
        }
        return await measured(items)
    }

    func matchingFormula(_ dir: String, in formulae: Set<String>) -> String? {
        if formulae.contains(dir) { return dir }
        if dir == "postgres" { return formulae.first { $0.hasPrefix("postgresql") } }
        if dir == "mysql" { return formulae.first { $0.hasPrefix("mysql") || $0.hasPrefix("mariadb") } }
        return nil
    }

    /// The three biggest databases in a running Postgres, like "app_dev 3.1 GB, app_test 200 MB".
    func largestDatabases(_ env: Environment, prefix: URL, formula: String) async -> String? {
        let psql = prefix.appending(path: "opt/\(formula)/bin/psql").path
        let sql = "select datname, pg_database_size(datname) from pg_database where not datistemplate order by 2 desc limit 3"
        let r = await env.runner.run([psql, "-d", "postgres", "-Atc", sql], timeout: .seconds(10))
        guard r.ok else { return nil }
        let parts = r.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let cols = line.split(separator: "|")
            guard cols.count == 2, let n = Int64(cols[1]) else { return nil }
            return "\(cols[0]) \(formatBytes(n))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for item in items where ids.contains(item.id) {
            if item.badges.contains(.running) {
                let how = item.id.hasPrefix("db.postgresapp.") ? "in Postgres.app" : item.id.hasPrefix("db.dbngin.") ? "in DBngin"
                    : "with brew services stop \(item.title)"
                plan.refusals.append(Refusal(itemID: item.id, reason: "Running database. Stop it first \(how)"))
                continue
            }
            if item.id.hasPrefix("db.postgresapp.") || item.id.hasPrefix("db.dbngin.") {
                plan.dangers.append("\(item.title) holds your databases. They'll be gone.")
            } else if !item.badges.contains(.orphaned) {
                plan.dangers.append("\(item.title) holds the databases of an installed Postgres or MySQL. They'll be gone.")
            }
            plan.steps.append(Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id))
        }
        return plan
    }
}

public func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
