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

            fillIPhone(model)
            model.selection = IPhoneDetail.id
            model.checked = [IPhoneDetail.id: [mediaID("/DCIM/109APPLE/IMG_0908.MOV"), mediaID("/DCIM/109APPLE/IMG_9758.MOV"), appID("com.example.streaming")]]
            let phone = await render(MainWindowRoot(model: model), size: NSSize(width: 980, height: 880), title: "Ballast", dark: dark)
            save(frame(phone), dir.appending(path: "iphone\(suffix).png"))
            model.checked = [:]

            let popover = await render(Popover(model: model), size: NSSize(width: 320, height: 420), title: nil, dark: dark, fit: true)
            save(frame(popover), dir.appending(path: "menu\(suffix).png"))
            model.reports.removeAll { $0.id == IPhoneDetail.id }
            model.iphone = nil

            fillMemory(model)
            let strained = await render(Popover(model: model), size: NSSize(width: 320, height: 420), title: nil, dark: dark, fit: true)
            save(frame(strained), dir.appending(path: "menu-memory\(suffix).png"))
            clearMemory(model)

            let settings = await render(SettingsView(model: model), size: NSSize(width: 520, height: 560), title: "Ballast Settings", dark: dark, fit: true)
            save(frame(settings), dir.appending(path: "settings\(suffix).png"))
        }
        exit(0)
    }

    // MARK: - Sample data

    /// A made-up strained Mac: an invented browser with a runaway helper and a made-up dev server, both owned by the current user.
    static func fillMemory(_ model: AppModel) {
        let me = getuid()
        func sample(_ pid: Int32, _ path: String, _ args: [String], _ gbs: Double) -> ProcessSample {
            ProcessSample(pid: pid, startSeconds: 1_700_000_000, uid: me, path: path, args: args, cwd: nil, footprint: Int64(gbs * Double(gb)))
        }
        let browser = [sample(41_001, "/Applications/Lumen Browser.app/Contents/MacOS/Lumen Browser", [], 1.2),
                       sample(41_002, "/Applications/Lumen Browser.app/Contents/Helpers/Lumen Helper", [], 3.1),
                       sample(41_003, "/Applications/Lumen Browser.app/Contents/Helpers/Lumen Helper", [], 2.4),
                       sample(41_004, "/Applications/Lumen Browser.app/Contents/Helpers/Lumen Helper", [], 1.4)]
        let server = [sample(42_001, "/usr/local/bin/node", ["node", "dev-server.js"], 2.2), sample(42_002, "/usr/local/bin/node", ["node", "dev-server.js"], 1.8)]
        let groups = [MemoryGroup(id: "app:/Applications/Lumen Browser.app", name: "Lumen Browser", processes: browser, bytes: browser.reduce(0) { $0 + $1.footprint }),
                      MemoryGroup(id: "cli:node dev-server.js", name: "node dev-server.js", processes: server, bytes: server.reduce(0) { $0 + $1.footprint })]
        let physical = 16 * gb
        model.memory.isRed = true
        model.memory.usedPercent = 91
        model.memory.swapUsed = 3_400 * mb
        model.memory.culprits = [
            Culprit(group: groups[0], share: Int(groups[0].bytes * 100 / physical), growth: 2 * gb, growthSeconds: 600),
            Culprit(group: groups[1], share: Int(groups[1].bytes * 100 / physical), growth: nil, growthSeconds: nil),
        ]
    }

    static func clearMemory(_ model: AppModel) {
        model.memory.isRed = false
        model.memory.usedPercent = nil
        model.memory.swapUsed = 0
        model.memory.culprits = []
    }

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

    static let udid = "00000000-0000000000000000"
    static func mediaID(_ path: String) -> String { "iphone.\(udid).media.\(path)" }
    static func appID(_ bundle: String) -> String { "iphone.\(udid).app.\(bundle)" }

    /// A made-up 64 GB iPhone that is nearly full.
    static func fillIPhone(_ model: AppModel) {
        func video(_ name: String, _ mb: Int64, _ date: String) -> Item {
            Item(id: mediaID("/DCIM/109APPLE/\(name)"), title: name, detail: "Video · \(date) · on iPhone", paths: [], bytes: mb * Self.mb, risk: .yourData)
        }
        func app(_ bundle: String, _ name: String, _ appMB: Int64, _ dataMB: Int64) -> Item {
            Item(id: appID(bundle), title: name, detail: "App \(formatBytes(appMB * Self.mb)) · Documents & Data \(formatBytes(dataMB * Self.mb))",
                 paths: [], bytes: (appMB + dataMB) * Self.mb, risk: .yourData)
        }
        let media = [video("IMG_0908.MOV", 277, "29 Sep 2025"), video("IMG_9758.MOV", 221, "27 Jun 2025"), video("IMG_9760.MOV", 196, "27 Jun 2025"),
                     video("IMG_0293.MP4", 181, "10 Aug 2025"), video("IMG_1802.MOV", 141, "1 Jan 2026"), video("IMG_1804.MOV", 119, "1 Jan 2026"),
                     video("IMG_0412.MOV", 64, "3 Mar 2026"), video("IMG_0177.MOV", 38, "12 Feb 2026")]
        let apps = [app("com.example.music", "Spotify", 280, 2_140), app("com.example.streaming", "YouTube", 352, 1_090), app("com.example.browser", "Brave", 340, 804),
                    app("com.example.chat", "Signal", 185, 653), app("com.example.work", "Slack", 349, 306), app("com.example.maps", "Maps Offline", 120, 410),
                    app("com.example.notes", "Notes Plus", 90, 150), app("com.example.bank", "Bank", 194, 303), app("com.example.fitness", "Run Club", 160, 95),
                    app("com.example.games", "Word Garden", 220, 540), app("com.example.camera", "Pocket Camera", 140, 780)]
        var snap = IPhoneSnapshot(state: .ready, udid: udid)
        snap.name = "Sample iPhone"
        snap.osVersion = "18.6.2"
        snap.capacity = 64 * gb
        snap.storage = IPhoneStorage(dataCapacity: 57_407_352_832, dataAvailable: 1_899_155_456, system: 6_559_047_680, photos: 16_729_113_438,
                                     apps: apps.reduce(0) { $0 + $1.bytes })
        snap.media = IPhoneMediaTally(photoCount: 3_386, photoBytes: 7_960 * mb, videoCount: 376, videoBytes: 7_750 * mb)
        snap.items = media + apps
        let p = Providers.all.first { $0.id == IPhoneDetail.id }!
        model.reports.insert(ConcernReport(id: p.id, title: p.title, section: p.section, symbol: p.symbol, items: snap.items, scannedAt: Date(), iphone: snap), at: 0)
        model.iphone = snap
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
        if title != nil { Windows.skin(w) } else { w.backgroundColor = NSColor(Theme.bg) }
        // Borderless windows (menu, sheet) get the window background a real menu or sheet would draw.
        let host = NSHostingView(rootView: view.background(Theme.bg))
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
