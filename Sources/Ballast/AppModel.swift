import AppKit
import BallastCore
import Foundation
import UserNotifications

@MainActor @Observable final class AppModel {
    var summary: Summary?
    var reports: [ConcernReport] = []
    var scanning = false
    var scanningIDs: Set<String> = []
    var free: Int64 = 0
    var total: Int64 = 0
    /// Nil when macOS won't let Ballast read the Trash.
    var trashBytes: Int64?
    /// The concern the main window shows.
    var selection: String?
    /// Ticked items, per concern.
    var checked: [String: Set<String>] = [:]
    /// The confirmation sheet's plan and its run.
    var run: RunState?
    /// Shown when macOS blocked Ballast from a protected folder.
    var permission: PermissionProblemInfo?
    var measuring: Set<String> = []
    let prefs = Preferences()
    let updates = UpdateCheck()
    /// Shows the "Where are your projects?" sheet.
    var firstRun = false

    @ObservationIgnored private var timer: Timer?

    static let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Ballast")
    static let summaryURL = support.appending(path: "summary.json")
    static let logURL = support.appending(path: "actions.log")

    static let shared = AppModel()

    private init() {
        Task { await launch() }
    }

    var env: Environment { .live(projectRoots: prefs.rootURLs) }
    var providers: [any Provider] {
        Providers.all.map { $0.id == "projects" ? ProjectLeftoversProvider(idleDays: prefs.idleDays) : $0 }
    }
    var scanner: DiskScanner { DiskScanner(env: env, providers: providers, summaryURL: Self.summaryURL) }

    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 1 }
    var lowSpace: Bool { total > 0 && freeFraction * 100 < Double(prefs.lowSpacePercent) }
    var safeToReclaim: Int64 { summary?.concerns.reduce(0) { $0 + $1.reclaimable } ?? 0 }

    func launch() async {
        summary = await scanner.lastSummary()
        refreshSpace()
        if !prefs.rootsConfirmed {
            firstRun = true
            Windows.shared.showMain(self)
        } else {
            startSchedule()
        }
        await measureTrash()
        await updates.check()
    }

    /// The first-run sheet's Continue.
    func confirmRoots(_ roots: [String]) async {
        prefs.projectRoots = roots
        prefs.rootsConfirmed = true
        firstRun = false
        startSchedule()
        await scanNow()
    }

    func refreshSpace() {
        let v = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        total = Int64(v?.volumeTotalCapacity ?? 0)
        if lowSpace { notifyLowSpace() }
    }

    func scanNow(only: Set<String>? = nil, background: Bool = false) async {
        guard !scanning else { return }
        scanning = true
        scanningIDs = only ?? Set(Providers.all.map(\.id))
        defer { scanning = false; scanningIDs = [] }
        let fresh = await scanner.scan(background: background, only: only)
        if let only {
            reports.removeAll { only.contains($0.id) }
            reports += fresh
            reports.sort { a, b in
                (Providers.all.firstIndex { $0.id == a.id } ?? 0) < (Providers.all.firstIndex { $0.id == b.id } ?? 0)
            }
        } else {
            // Keep a user-started concern (large files) that a full scan doesn't run.
            let kept = reports.filter { r in Providers.all.first { $0.id == r.id }?.needsUserStart == true }
            reports = fresh + kept
            summary = await scanner.lastSummary()
        }
        refreshSpace()
        await measureTrash()
    }

    func measureTrash() async {
        let m = await measure([FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")])
        trashBytes = m.partial && m.bytes == 0 ? nil : m.bytes
    }

    /// Asks first, then has Finder empty the Trash.
    func emptyTrash() async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash is deleted for good. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        if let error {
            let failed = NSAlert()
            failed.messageText = "Couldn't empty the Trash"
            failed.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Finder said no."
            failed.runModal()
        }
        refreshSpace()
        await measureTrash()
    }

    /// Checks hourly; scans in the background when the last summary is older than the interval.
    func startSchedule() {
        timer?.invalidate()
        timer = nil
        guard prefs.rescanHours > 0 else { return }
        let check = { [weak self] in
            Task { @MainActor in
                guard let self, !self.scanning else { return }
                let age = Date().timeIntervalSince(self.summary?.scannedAt ?? .distantPast)
                if age >= Double(self.prefs.rescanHours) * 3600 { await self.scanNow(background: true) }
            }
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in check() }
    }

    /// Drops the item lists when the main window closes; the summary stays.
    func releaseItems() {
        reports = []
    }

    func provider(_ id: String) -> (any Provider)? { providers.first { $0.id == id } }
    func report(_ id: String) -> ConcernReport? { reports.first { $0.id == id } }

    /// Builds the plan for ticked items (or an extra action) and opens the confirmation sheet.
    func prepare(concern: String, ids: [String]) async {
        guard let p = provider(concern), let r = report(concern) else { return }
        let plan = await p.plan(ids, items: r.items, env: env)
        run = RunState(provider: p, items: r.items, plan: plan)
    }

    func execute(_ state: RunState) async {
        state.phase = .running
        let before = free
        let executor = Executor(env: env, logURL: Self.logURL)
        let results = await executor.run(state.plan, provider: state.provider, items: state.items, pins: scanPins(roots: prefs.rootURLs)) { r in
            Task { @MainActor in state.outcomes[r.step.id] = r.outcome }
        }
        for r in results { state.outcomes[r.step.id] = r.outcome }
        state.trashed = results.filter { r in
            if case .trash = r.step.kind, r.outcome == .done { true } else { false }
        }.reduce(0) { $0 + $1.step.expectedBytes }
        checked[state.provider.id] = []
        await scanNow(only: [state.provider.id])
        state.freed = max(0, free - before)
        state.phase = .finished
        if let blocked = results.first(where: { $0.outcome == .failed(Executor.needsFullDiskAccess) }) {
            permission = PermissionProblemInfo(path: blocked.step.kind.firstPath, forgot: prefs.hadFullDiskAccess)
        }
    }

    /// Measures a locked item when the user asks. macOS may ask for access here.
    func measureLocked(concern: String, item: Item) async {
        measuring.insert(item.id)
        defer { measuring.remove(item.id) }
        let fresh = await measureProtected(item)
        guard let r = reports.firstIndex(where: { $0.id == concern }),
              let i = reports[r].items.firstIndex(where: { $0.id == item.id }) else { return }
        reports[r].items[i] = fresh
        if fresh.isLocked {
            permission = PermissionProblemInfo(path: item.paths.first, forgot: prefs.hadFullDiskAccess)
        } else {
            prefs.hadFullDiskAccess = true
        }
    }

    /// At most once a day.
    func notifyLowSpace() {
        let key = "lastLowSpaceNotice"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let free = formatBytes(self.free)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Disk almost full: \(free) left."
            content.body = "Open Ballast to see what's safe to remove."
            try? await center.add(UNNotificationRequest(identifier: "lowSpace", content: content, trigger: nil))
        }
    }
}
