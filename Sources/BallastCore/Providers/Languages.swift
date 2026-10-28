import Foundation

/// Versions of other languages: Java from SDKMAN and installed JDKs, Go from goenv
/// and ~/sdk, Rust toolchains from rustup, Elixir from kiex, PHP from phpenv, and
/// anything else asdf or mise installs.
public struct LanguagesProvider: Provider {
    public init() {}
    public let id = "languages"
    public let title = "Other languages"
    public let section = Section.toolchains
    public let symbol = "curlybraces"

    /// asdf plugin or mise tool names, with the name shown for each.
    static let tools: [(tool: String, name: String)] = [
        ("java", "Java"), ("golang", "Go"), ("go", "Go"), ("rust", "Rust"), ("erlang", "Erlang"), ("elixir", "Elixir"),
        ("php", "PHP"), ("deno", "Deno"), ("bun", "Bun"), ("zig", "Zig"), ("terraform", "Terraform"),
        ("kotlin", "Kotlin"), ("scala", "Scala"), ("gradle", "Gradle"), ("maven", "Maven"),
    ]
    static let jvms = "Library/Java/JavaVirtualMachines"

    public func isPresent(_ env: Environment) async -> Bool {
        [".sdkman/candidates", Self.jvms, ".goenv/versions", "sdk", ".rustup/toolchains", ".kiex/elixirs", ".phpenv/versions"]
            .contains { exists(env.path($0)) }
            || exists(env.system(Self.jvms))
            || Self.tools.contains { exists(env.path(".asdf/installs/\($0.tool)")) || exists(miseInstalls(env, tool: $0.tool)) }
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        func add(_ manager: String, _ tool: String, _ name: String, folder: URL, title: String, version: String,
                 isDefault: Bool, id: String? = nil) {
            var badges = Set<Badge>()
            if isDefault { badges.insert(.isDefault) }
            if let language = languageName(forTool: tool),
               let pin = pinBadge(pins, pins.other[language] ?? [:], installed: version) { badges.insert(pin) }
            items.append(Item(id: id ?? "lang.\(manager).\(tool).\(name)", title: title, detail: manager,
                              paths: [folder], bytes: 0, risk: .regenerable, badges: badges))
        }
        func display(_ tool: String) -> String { Self.tools.first { $0.tool == tool }?.name ?? tool.capitalized }

        // SDKMAN: candidates/<tool>/<version>, with a `current` link to the default.
        let sdkman = env.path(".sdkman/candidates")
        for tool in subfolders(sdkman) {
            let dir = sdkman.appending(path: tool)
            let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "current").path))
                .map { URL(filePath: $0).lastPathComponent }
            for v in subfolders(dir) {
                let shown = tool == "java" ? javaVersion(dir.appending(path: "\(v)/release")) ?? v : v
                add("sdkman", tool, v, folder: dir.appending(path: v), title: "\(display(tool)) \(shown)", version: shown,
                    isDefault: v == current)
            }
        }

        // JDKs from installers live in /Library and need an administrator; IDEs download theirs to ~/Library.
        let jvmRoots = [(env.system(Self.jvms), "jvm"), (env.path(Self.jvms), "userjvm")]
        for (root, manager) in jvmRoots where manager == "jvm" || root.standardizedFileURL != jvmRoots[0].0.standardizedFileURL {
            for name in subfolders(root) where name.hasSuffix(".jdk") {
                let folder = root.appending(path: name)
                let v = javaVersion(folder.appending(path: "Contents/Home/release")) ?? name
                add(manager, "java", name, folder: folder, title: "Java \(v)", version: v, isDefault: false,
                    id: "lang.\(manager).\(name)")
            }
        }

        let goenvDefault = firstLine(env.path(".goenv/version"))
        for v in subfolders(env.path(".goenv/versions")) {
            add("goenv", "go", v, folder: env.path(".goenv/versions/\(v)"), title: "Go \(v)", version: v, isDefault: v == goenvDefault)
        }
        for name in subfolders(env.path("sdk")) where name.hasPrefix("go") {
            let v = String(name.dropFirst(2))
            guard v.first?.isNumber == true else { continue }
            add("gosdk", "go", v, folder: env.path("sdk/\(name)"), title: "Go \(v)", version: v, isDefault: false)
        }

        // rustup toolchains are named channel-host: stable-aarch64-apple-darwin, 1.75.0-aarch64-apple-darwin.
        let rustDefault = (try? String(contentsOf: env.path(".rustup/settings.toml"), encoding: .utf8))
            .flatMap { $0.firstMatch(of: /(?m)^\s*default_toolchain\s*=\s*"([^"]+)"/) }.map { String($0.1) }
        for name in subfolders(env.path(".rustup/toolchains")) {
            let channel = String(name.prefix { $0 != "-" })
            add("rustup", "rust", name, folder: env.path(".rustup/toolchains/\(name)"), title: "Rust \(channel)",
                version: channel, isDefault: name == rustDefault || channel == rustDefault)
        }

        for name in subfolders(env.path(".kiex/elixirs")) where name.hasPrefix("elixir-") {
            let v = String(name.dropFirst(7))
            add("kiex", "elixir", v, folder: env.path(".kiex/elixirs/\(name)"), title: "Elixir \(v)", version: v, isDefault: false)
        }
        let phpenvDefault = firstLine(env.path(".phpenv/version"))
        for v in subfolders(env.path(".phpenv/versions")) {
            add("phpenv", "php", v, folder: env.path(".phpenv/versions/\(v)"), title: "PHP \(v)", version: v, isDefault: v == phpenvDefault)
        }

        for (tool, name) in Self.tools {
            let asdf = env.path(".asdf/installs/\(tool)")
            let asdfDefault = asdfGlobal(env, tool: tool)
            for v in subfolders(asdf) {
                add("asdf", tool, v, folder: asdf.appending(path: v), title: "\(name) \(v)", version: v, isDefault: v == asdfDefault)
            }
            let mise = miseInstalls(env, tool: tool)
            let versions = subfolders(mise)
            let miseDefault = miseGlobal(env, tools: [tool], installed: versions)
            for v in versions {
                add("mise", tool, v, folder: mise.appending(path: v), title: "\(name) \(v)", version: v, isDefault: v == miseDefault)
            }
        }
        return await measured(items)
    }

    /// `JAVA_VERSION="21.0.2"` from a JDK's release file.
    func javaVersion(_ release: URL) -> String? {
        (try? String(contentsOf: release, encoding: .utf8))
            .flatMap { $0.firstMatch(of: /(?m)^JAVA_VERSION="([^"]+)"/) }.map { String($0.1) }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let sdkInit = "source \(shellQuote(env.path(".sdkman/bin/sdkman-init.sh").path))"
        return planEach(ids, items: items, noun: "version") { item in
            let parts = item.id.split(separator: ".", maxSplits: 3).map(String.init)
            let manager = parts[1]
            let tool = parts.count > 3 ? parts[2] : "", name = parts.count > 3 ? parts[3] : ""
            let kind: StepKind = switch manager {
            case "sdkman": .shell("\(sdkInit) && sdk uninstall \(shellQuote(tool)) \(shellQuote(name))")
            case "jvm": .copyToTerminal("sudo rm -rf \(shellQuote(item.paths[0].path))")
            case "goenv": .command(argv: ["goenv", "uninstall", "-f", name])
            case "rustup": .command(argv: ["rustup", "toolchain", "uninstall", name])
            case "asdf": .command(argv: ["asdf", "uninstall", tool, name])
            case "mise": .command(argv: ["mise", "uninstall", "\(tool)@\(name)"])
            default: .trash(item.paths)
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
    }
}
