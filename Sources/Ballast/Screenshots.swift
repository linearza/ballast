import AppKit
import BallastCore
import SwiftUI

/// `BALLAST_SCREENSHOTS=<dir> Ballast.app/Contents/MacOS/Ballast` fills the app with made-up data,
/// renders its windows to PNGs in `dir` and quits. Nothing on this Mac is scanned or shown.
@MainActor enum Screenshots {
    static let directory = ProcessInfo.processInfo.environment["BALLAST_SCREENSHOTS"].map { URL(filePath: $0) }

    /// Throwaway settings, so the screenshots never show (or change) the real ones.
    static var defaults: UserDefaults {
        let name = "za.co.linear.ballast.screenshots"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    static func capture(_ model: AppModel, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fill(model)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            model.selection = "ruby"
            model.checked = ["ruby": ["ruby.rvm.2.7.8", "ruby.rvm.3.0.6", "ruby.rvm.downloads"]]
            let main = await render(MainWindowRoot(model: model), size: NSSize(width: 980, height: 600), title: "Ballast", dark: dark)
            save(frame(main), dir.appending(path: "main\(suffix).png"))

            model.selection = "projects"
            model.checked = ["projects": ["project.nm.storefront-legacy", "project.wt.storefront-checkout"]]
            let projects = await render(MainWindowRoot(model: model), size: NSSize(width: 980, height: 600), title: "Ballast", dark: dark)
            save(frame(projects), dir.appending(path: "projects\(suffix).png"))

            model.selection = "ruby"
            model.checked = ["ruby": ["ruby.rvm.2.7.8", "ruby.rvm.3.0.6", "ruby.rvm.downloads", "ruby.rvm.3.2.2"]]
            let sheet = await render(ConfirmSheet(model: model, state: confirmState(model)), size: NSSize(width: 560, height: 560), title: nil, dark: dark)
            save(frame(main, sheet: sheet), dir.appending(path: "confirm\(suffix).png"))

            model.selection = "aiModels"
            model.checked = ["aiModels": ["ai.hf.stabilityai/stable-diffusion-xl-base-1.0", "ai.lmstudio.lmstudio-community"]]
            let models = await render(MainWindowRoot(model: model), size: NSSize(width: 980, height: 600), title: "Ballast", dark: dark)
            save(frame(models), dir.appending(path: "models\(suffix).png"))

            model.selection = SafeView.id
            model.checked = [:]
            let safe = await render(MainWindowRoot(model: model), size: NSSize(width: 980, height: 600), title: "Ballast", dark: dark)
            save(frame(safe), dir.appending(path: "safe\(suffix).png"))

            let popover = await render(Popover(model: model), size: NSSize(width: 320, height: 420), title: nil, dark: dark, fit: true)
            save(frame(popover), dir.appending(path: "menu\(suffix).png"))

            let settings = await render(SettingsView(model: model), size: NSSize(width: 520, height: 560), title: "Ballast Settings", dark: dark, fit: true)
            save(frame(settings), dir.appending(path: "settings\(suffix).png"))
        }
        exit(0)
    }

    // MARK: - Sample data

    static let home = "/Users/you"
    static let day: TimeInterval = 86_400
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000

    static func item(_ id: String, _ title: String, _ detail: String? = nil, _ path: String, _ bytes: Int64,
                     _ risk: Risk = .regenerable, _ badges: Set<Badge> = []) -> Item {
        Item(id: id, title: title, detail: detail, paths: [URL(filePath: home + "/" + path)], bytes: bytes, risk: risk, badges: badges)
    }

    static func report(_ id: String, _ items: [Item]) -> ConcernReport {
        let p = Providers.all.first { $0.id == id }!
        return ConcernReport(id: id, title: p.title, section: p.section, symbol: p.symbol, items: items, scannedAt: Date())
    }

    static func fill(_ model: AppModel) {
        let now = Date()
        model.reports = [
            report("ruby", [
                item("ruby.rvm.3.3.6", "Ruby 3.3.6", "RVM · with gems", ".rvm/rubies/ruby-3.3.6", 812 * mb, .regenerable, [.isDefault, .pinned(by: ["storefront"])]),
                item("ruby.rvm.3.2.2", "Ruby 3.2.2", "RVM · with gems", ".rvm/rubies/ruby-3.2.2", 1_240 * mb, .regenerable, [.pinned(by: ["billing-api"])]),
                item("ruby.rvm.3.0.6", "Ruby 3.0.6", "RVM · with gems", ".rvm/rubies/ruby-3.0.6", 1_630 * mb),
                item("ruby.rvm.2.7.8", "Ruby 2.7.8", "RVM · with gems", ".rvm/rubies/ruby-2.7.8", 2_110 * mb),
                item("ruby.rvm.downloads", "RVM downloads and sources", "~/.rvm/src, ~/.rvm/archives", ".rvm/src", 960 * mb),
                item("ruby.rvm.backup", "RVM backups", "~/.rvm/backup", ".rvm/backup", 214 * mb, .review),
            ]),
            report("node", [
                item("node.nvm.v22.11.0", "Node 22.11.0", "nvm · with global packages", ".nvm/versions/node/v22.11.0", 196 * mb, .regenerable, [.isDefault]),
                item("node.nvm.v20.18.0", "Node 20.18.0", "nvm · with global packages", ".nvm/versions/node/v20.18.0", 188 * mb, .regenerable, [.pinned(by: ["storefront", "docs-site"])]),
                item("node.nvm.v18.20.4", "Node 18.20.4", "nvm · with global packages", ".nvm/versions/node/v18.20.4", 171 * mb),
                item("node.nvm.v16.20.2", "Node 16.20.2", "nvm · with global packages", ".nvm/versions/node/v16.20.2", 164 * mb),
                item("node.nvm.cache", "nvm download cache", "~/.nvm/.cache", ".nvm/.cache", 412 * mb),
            ]),
            report("docker", [
                item("docker.data", "Docker disk image", "Images, containers, volumes and build cache", "Library/Containers/com.docker.docker/Data", 38 * gb, .review),
                item("docker.app", "Docker Desktop", "/Applications/Docker.app", "Applications/Docker.app", 2_100 * mb, .review),
            ]),
            report("projects", [
                item("project.nm.storefront-legacy", "storefront-legacy node_modules", "Last commit 9 months ago", "Code/storefront-legacy/node_modules", 1_480 * mb, .regenerable, [.lastUsed(now - 270 * day)]),
                item("project.nm.marketing-site", "marketing-site node_modules", "Last commit 4 months ago", "Code/marketing-site/node_modules", 690 * mb, .regenerable, [.lastUsed(now - 120 * day)]),
                item("project.nm.storefront", "storefront node_modules", "Last commit today", "Code/storefront/node_modules", 1_120 * mb, .review, [.lastUsed(now)]),
                item("project.wt.storefront-checkout", "storefront worktree checkout-redesign", "~/Code/storefront-wt/checkout-redesign", "Code/storefront-wt/checkout-redesign", 2_310 * mb, .regenerable, [.mergedPR]),
                item("project.wt.storefront-search", "storefront worktree search-v2", "~/Code/storefront-wt/search-v2", "Code/storefront-wt/search-v2", 1_870 * mb, .review, [.openPR, .uncommitted(3)]),
                item("project.wt.billing-retry", "billing-api worktree retry-webhooks", "~/Code/billing-api-wt/retry-webhooks", "Code/billing-api-wt/retry-webhooks", 640 * mb, .review, [.mergedPR, .unpushed(2)]),
            ]),
            report("packageCaches", [
                item("cache.npm", "npm cache", "~/.npm/_cacache", ".npm/_cacache", 4_200 * mb),
                item("cache.yarn", "Yarn (classic) cache", "~/Library/Caches/Yarn", "Library/Caches/Yarn", 2_600 * mb),
                item("cache.pip", "pip cache", "~/Library/Caches/pip", "Library/Caches/pip", 1_300 * mb),
                item("cache.cocoapods", "CocoaPods cache", "~/Library/Caches/CocoaPods", "Library/Caches/CocoaPods", 880 * mb),
            ]),
            report("xcode", [
                item("xcode.runtime.ios17", "Simulator runtime iOS 17.5", nil, "Library/Developer/CoreSimulator/Volumes/iOS_21F79", 7_900 * mb),
                item("xcode.derived", "DerivedData", "~/Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/DerivedData", 6_400 * mb),
                item("xcode.device", "iPhone 15 simulator", "iOS 17.5 · unavailable", "Library/Developer/CoreSimulator/Devices/A1", 2_300 * mb),
            ]),
            report("aiModels", [
                item("ai.ollama.llama3.1:8b", "llama3.1:8b", "Ollama", ".ollama/models/manifests/llama3.1", 4_900 * mb, .review),
                item("ai.ollama.qwen2.5-coder:14b", "qwen2.5-coder:14b", "Ollama", ".ollama/models/manifests/qwen2.5-coder", 9_000 * mb, .review),
                item("ai.hf.openai/whisper-large-v3", "openai/whisper-large-v3 (Hugging Face)", "~/.cache/huggingface/hub/models--openai--whisper-large-v3",
                     ".cache/huggingface/hub/models--openai--whisper-large-v3", 3_100 * mb, .review),
                item("ai.hf.stabilityai/stable-diffusion-xl-base-1.0", "stabilityai/stable-diffusion-xl-base-1.0 (Hugging Face)",
                     "~/.cache/huggingface/hub/models--stabilityai--stable-diffusion-xl-base-1.0",
                     ".cache/huggingface/hub/models--stabilityai--stable-diffusion-xl-base-1.0", 13_900 * mb, .review),
                item("ai.lmstudio.lmstudio-community", "lmstudio-community (LM Studio)", "~/.lmstudio/models/lmstudio-community",
                     ".lmstudio/models/lmstudio-community", 4_400 * mb, .review),
            ]),
            report("databases", [
                item("db.postgresql@14", "postgresql@14", "Homebrew · data in /opt/homebrew/var/postgresql@14", "postgres14", 3_400 * mb, .yourData, [.running]),
                item("db.mysql", "mysql", "Homebrew · stopped", "mysql", 1_200 * mb, .yourData),
            ]),
            report("homebrew", [
                item("brew.cleanup", "Old versions and downloads", "brew cleanup --prune=all", "Library/Caches/Homebrew", 2_700 * mb),
                item("brew.autoremove", "Unused dependencies", "11 formulae nothing depends on", "opt", 540 * mb),
            ]),
        ]
        model.free = 61 * gb
        model.total = 494 * gb
        model.trashBytes = 1_800 * mb
        model.summary = Summary(reports: model.reports, freeBytes: model.free, totalBytes: model.total, scannedAt: now - 3 * 3600)
        model.prefs.projectRoots = [home + "/Code", home + "/Work"].map { $0.replacingOccurrences(of: home, with: NSHomeDirectory()) }
        model.prefs.rootsConfirmed = true
    }

    static func confirmState(_ model: AppModel) -> RunState {
        let report = model.report("ruby")!
        let ids = ["ruby.rvm.2.7.8", "ruby.rvm.3.0.6", "ruby.rvm.downloads"]
        let items = report.items.filter { ids.contains($0.id) || $0.id == "ruby.rvm.3.2.2" }
        let source = "source \(home)/.rvm/scripts/rvm"
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let plan = Plan(steps: [
            Step("Remove Ruby 2.7.8", .shell("\(source) && rvm remove ruby-2.7.8 --gems"), bytes: byID["ruby.rvm.2.7.8"]!.bytes, itemID: "ruby.rvm.2.7.8"),
            Step("Remove Ruby 3.0.6", .shell("\(source) && rvm remove ruby-3.0.6 --gems"), bytes: byID["ruby.rvm.3.0.6"]!.bytes, itemID: "ruby.rvm.3.0.6"),
            Step("Remove RVM downloads and sources", .shell("\(source) && rvm cleanup archives && rvm cleanup sources"), bytes: byID["ruby.rvm.downloads"]!.bytes, itemID: "ruby.rvm.downloads"),
            Step("Remove Ruby 3.2.2", .shell("\(source) && rvm remove ruby-3.2.2 --gems"), bytes: byID["ruby.rvm.3.2.2"]!.bytes, itemID: "ruby.rvm.3.2.2"),
        ], dangers: ["Ruby 3.2.2 is pinned by billing-api."])
        return RunState(provider: model.provider("ruby")!, items: items, plan: plan)
    }

    // MARK: - Rendering

    /// Draws `view` in an invisible window and returns its pixels, title bar included.
    static func render(_ view: some View, size: NSSize, title: String?, dark: Bool, fit: Bool = false) async -> NSBitmapImageRep {
        let style: NSWindow.StyleMask = title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title ?? ""
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.alphaValue = 0
        w.isReleasedWhenClosed = false
        // Borderless windows (menu, sheet) get the window background a real menu or sheet would draw.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        w.contentView = host
        if fit { w.setContentSize(host.fittingSize) } else { w.setContentSize(size) }
        w.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))
        let target = title == nil ? host : (host.superview ?? host)
        target.layoutSubtreeIfNeeded()
        let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds)!
        target.cacheDisplay(in: target.bounds, to: rep)
        w.orderOut(nil)
        return rep
    }

    /// Rounds the corners and adds a soft shadow on a transparent margin; `sheet` is laid over the window like a sheet.
    static func frame(_ window: NSBitmapImageRep, sheet: NSBitmapImageRep? = nil) -> NSBitmapImageRep {
        let scale = CGFloat(window.pixelsWide) / window.size.width
        let margin: CGFloat = 40, radius: CGFloat = 12
        let size = NSSize(width: window.size.width + margin * 2, height: window.size.height + margin * 2)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        func draw(_ rep: NSBitmapImageRep, in rect: NSRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            rep.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.gray.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let windowRect = NSRect(origin: NSPoint(x: margin, y: margin), size: window.size)
        draw(window, in: windowRect)
        if let sheet {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: windowRect, xRadius: radius, yRadius: radius).fill()
            let x = windowRect.midX - sheet.size.width / 2
            let y = windowRect.maxY - 52 - sheet.size.height
            draw(sheet, in: NSRect(origin: NSPoint(x: x, y: y), size: sheet.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func save(_ rep: NSBitmapImageRep, _ url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
