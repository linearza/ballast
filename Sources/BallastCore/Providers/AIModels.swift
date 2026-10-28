import Foundation

/// Local AI models: Ollama, Hugging Face, Whisper, LM Studio, GPT4All, Jan, llama.cpp,
/// DiffusionBee, Draw Things and PyTorch Hub.
public struct AIModelsProvider: Provider {
    public init() {}
    public let id = "aiModels"
    public let title = "AI models"
    public let section = Section.ai
    public let symbol = "brain"

    static let uninstallOllama = "ai.ollama.uninstall"
    /// Folders in ~/Library/Caches that hold models, so AppCaches leaves them out.
    static let claimedCacheNames: Set<String> = ["llama.cpp"]
    static let drawThings = "Library/Containers/com.liuliu.draw-things/Data/Documents/Models"

    func ollamaRoot(_ env: Environment) -> URL { env.path(".ollama/models") }

    struct OllamaModel {
        var name: String
        var manifest: URL
        var blobs: [URL]
    }

    func ollamaModels(_ env: Environment) -> [OllamaModel] {
        let library = ollamaRoot(env).appending(path: "manifests/registry.ollama.ai/library")
        return subfolders(library).sorted().flatMap { name -> [OllamaModel] in
            let dir = library.appending(path: name)
            let tags = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            return tags.map { tag in
                let manifest = dir.appending(path: tag)
                return OllamaModel(name: "\(name):\(tag)", manifest: manifest, blobs: blobs(manifest, env: env))
            }
        }
    }

    func blobs(_ manifest: URL, env: Environment) -> [URL] {
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let config = (json["config"] as? [String: Any]).map { [$0] } ?? []
        let layers = json["layers"] as? [[String: Any]] ?? []
        // Only well-formed digests, so a crafted manifest can't point outside the blobs folder.
        return (config + layers).compactMap { $0["digest"] as? String }.filter(isSHA256Digest).map {
            ollamaRoot(env).appending(path: "blobs/\($0.replacingOccurrences(of: ":", with: "-"))")
        }
    }

    func modelDirs(_ env: Environment) -> [(id: String, title: String, url: URL)] {
        var out: [(String, String, URL)] = []
        let hf = env.path(".cache/huggingface/hub")
        for name in subfolders(hf).sorted() where name.hasPrefix("models--") {
            let model = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            out.append(("ai.hf.\(model)", "\(model) (Hugging Face)", hf.appending(path: name)))
        }
        for name in subfolders(env.path(".cache")).sorted() where name.hasPrefix("whisper") {
            out.append(("ai.whisper.\(name)", "Whisper models", env.path(".cache/\(name)")))
        }
        let lm = env.path(".lmstudio/models")
        for name in subfolders(lm).sorted() where !name.hasPrefix(".") {
            out.append(("ai.lmstudio.\(name)", "\(name) (LM Studio)", lm.appending(path: name)))
        }
        func files(_ dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".gguf") || $0.hasSuffix(".bin") }.sorted()
        }
        let gpt4all = env.path("Library/Application Support/nomic.ai/GPT4All")
        for name in files(gpt4all) {
            out.append(("ai.gpt4all.\(name)", "\(name) (GPT4All)", gpt4all.appending(path: name)))
        }
        for dir in ["jan/models", "Library/Application Support/Jan/data/models", "Library/Application Support/Jan/data/llamacpp/models"] {
            for name in subfolders(env.path(dir)) where !out.contains(where: { $0.0 == "ai.jan.\(name)" }) {
                out.append(("ai.jan.\(name)", "\(name) (Jan)", env.path("\(dir)/\(name)")))
            }
        }
        let llama = env.path("Library/Caches/llama.cpp")
        for name in files(llama) {
            out.append(("ai.llamacpp.\(name)", "\(name) (llama.cpp)", llama.appending(path: name)))
        }
        if exists(env.path(".diffusionbee")) { out.append(("ai.diffusionbee", "DiffusionBee models", env.path(".diffusionbee"))) }
        if exists(env.path(".cache/torch/hub")) { out.append(("ai.torch", "PyTorch Hub models", env.path(".cache/torch/hub"))) }
        return out
    }

    public func isPresent(_ env: Environment) async -> Bool {
        exists(env.path(".ollama")) || !modelDirs(env).isEmpty || exists(env.path(Self.drawThings))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items = ollamaModels(env).map { m in
            Item(id: "ai.ollama.\(m.name)", title: m.name, detail: "Ollama", paths: [m.manifest] + m.blobs.filter(exists), bytes: 0, risk: .review)
        }
        items += modelDirs(env).map { Item(id: $0.id, title: $0.title, detail: $0.url.path, paths: [$0.url], bytes: 0, risk: .review) }
        var all = await measured(items)
        if exists(env.path(Self.drawThings)) {
            all.append(lockedItem(id: "ai.drawthings", title: "Draw Things models", detail: "Kept in Draw Things' private folder",
                                  paths: [env.path(Self.drawThings)], risk: .review))
        }
        return all
    }

    public func extraActions(_ items: [Item]) -> [ProviderAction] {
        let ollama = items.filter { $0.id.hasPrefix("ai.ollama.") }
        return ollama.isEmpty ? [] : [ProviderAction(id: Self.uninstallOllama, title: "Uninstall Ollama completely", itemIDs: ollama.map(\.id))]
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        if ids.contains(Self.uninstallOllama) { return await uninstallPlan(items, env: env) }
        var plan = Plan()
        let models = ollamaModels(env)
        let removing = Set(ids)
        var serverUp = false
        if await env.runner.which("ollama") != nil { serverUp = await env.runner.run(["ollama", "list"], timeout: .seconds(10)).ok }
        // Blobs still needed by models that stay.
        let kept = Set(models.filter { !removing.contains("ai.ollama.\($0.name)") }.flatMap(\.blobs).map(\.path))
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if id.hasPrefix("ai.ollama."), let m = models.first(where: { "ai.ollama.\($0.name)" == id }) {
                if serverUp {
                    plan.steps.append(Step("Remove \(m.name)", .command(argv: ["ollama", "rm", m.name]), bytes: item.bytes, itemID: id))
                } else {
                    let own = m.blobs.filter { !kept.contains($0.path) && exists($0) }
                    plan.steps.append(Step("Move \(m.name) to the Trash", .trash([m.manifest] + own), bytes: item.bytes, itemID: id))
                }
            } else {
                plan.steps.append(Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: id))
            }
        }
        return plan
    }

    func uninstallPlan(_ items: [Item], env: Environment) async -> Plan {
        var plan = Plan(dangers: ["This removes Ollama and every model it downloaded."])
        let formulas = await env.runner.run(["brew", "list", "--formula"], timeout: .seconds(30))
        if formulas.ok, formulas.stdout.split(whereSeparator: \.isNewline).contains("ollama") {
            plan.steps.append(Step("Uninstall Ollama with Homebrew", .command(argv: ["brew", "uninstall", "ollama"])))
        }
        let paths = env.applications.map { $0.appending(path: "Ollama.app") }
            + [env.path(".ollama"), env.path("Library/Application Support/Ollama"), env.path("Library/Caches/ollama")]
        let present = paths.filter(exists)
        if !present.isEmpty {
            let bytes = items.filter { $0.id.hasPrefix("ai.ollama.") }.reduce(0) { $0 + $1.bytes }
            plan.steps.append(Step("Move Ollama and its models to the Trash", .trash(present), bytes: bytes))
        }
        return plan
    }
}

/// `sha256:` followed by 64 lowercase hex digits.
func isSHA256Digest(_ s: String) -> Bool {
    guard s.hasPrefix("sha256:") else { return false }
    let hex = s.dropFirst(7)
    return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}
