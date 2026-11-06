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
    var trash: TrashState = .unknown
    /// The concern the main window shows.
    var selection: String?
    /// Ticked items, per concern.
    var checked: [String: Set<String>] = [:]
    /// The confirmation sheet's plan and its run.
    var run: RunState?
    /// Shown when macOS blocked Ballast from a protected folder.
    var permission: PermissionProblemInfo?
    var measuring: Set<String> = []
    /// The connected iPhone, kept when the main window closes so the menu can say how much space it has.
    var iphone: IPhoneSnapshot?
    let prefs: Preferences
    let updates = UpdateCheck()
    let imageCapture = ImageCaptureTransfer()
    /// Shows the "Where are your projects?" sheet.
    var firstRun = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: IPhoneWatcher?
    @ObservationIgnored private var rescanQueue = IPhoneRescanQueue()
    /// The pending settle-then-rescan, replaced by each new attach so a burst becomes one rescan.
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lockedAttempts = 0

    static let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Ballast")
    static let summaryURL = support.appending(path: "summary.json")
    static let logURL = support.appending(path: "actions.log")

    static let shared = AppModel()

    private init() {
        if let dir = Screenshots.directory {
            prefs = Preferences(defaults: Screenshots.defaults)
            Task { await Screenshots.capture(self, to: dir) }
        } else {
            prefs = Preferences()
            Task { await launch() }
            startIPhoneWatcher()
        }
    }

    var env: Environment { .live(projectRoots: prefs.rootURLs) }
    var providers: [any Provider] {
        Providers.all.map { p in
            switch p.id {
            case "projects": ProjectLeftoversProvider(idleDays: prefs.idleDays)
            case "iphone": IPhoneProvider(destination: prefs.iphoneFolderURL)
            default: p
            }
        }
    }
    var scanner: DiskScanner { DiskScanner(env: env, providers: providers, summaryURL: Self.summaryURL) }

    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 1 }
    var lowSpace: Bool { total > 0 && freeFraction * 100 < Double(prefs.lowSpacePercent) }
    var safeToReclaim: Int64 { summary?.concerns.reduce(0) { $0 + $1.reclaimable } ?? 0 }

    func launch() async {
        UNUserNotificationCenter.current().delegate = NotificationClicks.shared
        summary = await scanner.lastSummary()
        refreshSpace()
        if !prefs.rootsConfirmed {
            firstRun = true
            Windows.shared.showMain(self)
        } else {
            startSchedule()
        }
        await measureTrash()
        await updates.check(notifying: !prefs.quiet)
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
        if only == nil || only?.contains("iphone") == true {
            iphone = report("iphone")?.iphone
            scheduleLockedRetry()
        }
        refreshSpace()
        await measureTrash()
        runQueuedIPhoneRescan()
    }

    // MARK: - Plug and unplug

    func startIPhoneWatcher() {
        guard watcher == nil else { return }
        let w = IPhoneWatcher(onAttach: { [weak self] in self?.iphoneAttached() }, onDetach: { [weak self] in self?.iphoneDetached() })
        w.start()
        watcher = w
    }

    /// Waits a moment for usbmuxd to register the phone, then rescans just the iPhone.
    private func iphoneAttached() {
        lockedAttempts = 0
        queueIPhoneRescan(after: IPhoneWatch.settleDelay)
    }

    /// Takes the phone off the menu and the sidebar at once.
    private func iphoneDetached() {
        settleTask?.cancel()
        rescanQueue.cancel()
        lockedAttempts = 0
        iphone = nil
        reports.removeAll { $0.id == "iphone" }
    }

    private func queueIPhoneRescan(after delay: TimeInterval) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            rescanQueue.request()
            runQueuedIPhoneRescan()
        }
    }

    /// Starts the wanted rescan unless a scan is running; the running scan calls this again when it ends.
    private func runQueuedIPhoneRescan() {
        guard rescanQueue.take(scanning: scanning) else { return }
        Task { await scanNow(only: ["iphone"], background: true) }
    }

    /// A phone that answered "locked" gets a look again at 10 s and 30 s, so it fills in after Unlock and Trust.
    private func scheduleLockedRetry() {
        guard iphone?.state == .locked else { lockedAttempts = 0; return }
        lockedAttempts += 1
        if let delay = IPhoneWatch.lockedRetryDelay(afterAttempt: lockedAttempts) { queueIPhoneRescan(after: delay) }
    }

    func measureTrash() async {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        // Without Full Disk Access the folder can't be read, so Finder is asked (read-only, via Automation).
        trash = await trashState(at: folder) { await MainActor.run { Self.askFinderAboutTrash() } }
    }

    /// Item count and size from Finder. Nil if Finder won't say (e.g. Automation was refused).
    private static func askFinderAboutTrash() -> FinderTrash? {
        let source = """
        tell application "Finder"
            set n to count of items of trash
            set s to missing value
            try
                set s to physical size of trash
            end try
            return (n as text) & ", " & (s as text)
        end tell
        """
        var error: NSDictionary?
        guard let reply = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil,
              let text = reply.stringValue else { return nil }
        return FinderTrash.parse(text)
    }

    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Asks first, then has Finder empty the Trash.
    func emptyTrash() async {
        NSApp.activate(ignoringOtherApps: true)
        await measureTrash()
        guard trash != .empty else { return }
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash is deleted for good, including things you put there before. This can't be undone."
        let empty = alert.addButton(withTitle: "Empty Trash")
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return cancels: deleting for good takes a deliberate click.
        empty.hasDestructiveAction = true
        empty.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        // Finder errors when there's nothing to empty; if it's empty now, that's the outcome we wanted.
        if error != nil { await measureTrash() }
        if let error, trash.shouldReportFailure {
            let failed = NSAlert()
            failed.messageText = "Couldn't empty the Trash"
            // -1743: the user (or macOS, for an app without a usage description) said no to controlling Finder.
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                failed.informativeText = "Ballast isn't allowed to ask Finder. Turn on Finder under Ballast in Privacy & Security → Automation, or empty the Trash from the Dock."
                failed.addButton(withTitle: "Open Settings")
                failed.addButton(withTitle: "OK")
                if failed.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.automationSettingsURL) }
            } else {
                failed.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Finder said no."
                failed.runModal()
            }
        }
        refreshSpace()
        await measureTrash()
    }

    /// Checks hourly for updates, and scans in the background when the last summary is older than the interval.
    func startSchedule() {
        timer?.invalidate()
        timer = nil
        Task { await scheduledCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scheduledCheck() }
        }
    }

    func scheduledCheck() async {
        // Menu bar apps stay open for weeks; `check` itself asks GitHub at most once a day.
        await updates.check(notifying: !prefs.quiet)
        guard prefs.rescanHours > 0, !scanning else { return }
        let age = Date().timeIntervalSince(summary?.scannedAt ?? .distantPast)
        if age >= Double(prefs.rescanHours) * 3600 { await scanNow(background: true) }
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
        // A double-click or a second Return must not run the plan twice.
        guard state.phase == .confirm else { return }
        state.phase = .running
        let before = free
        let executor = Executor(env: env, logURL: Self.logURL, iphone: imageCapture)
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
        if results.contains(where: { $0.outcome == .failed(ImageCaptureTransfer.deniedMessage) }) { explainIPhoneAccess() }
        if let blocked = results.first(where: { $0.outcome == .failed(Executor.needsFullDiskAccess) }) {
            permission = PermissionProblemInfo(path: blocked.step.kind.firstPath, forgot: prefs.hadFullDiskAccess)
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!

    /// macOS refused Ballast the iPhone's photos: say so, and offer the pane where that's changed.
    func explainIPhoneAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ballast can't open the iPhone's photos"
        alert.informativeText = "macOS asks before an app reads photos from an iPhone, and it was turned down. Allow Ballast under Privacy & Security (Photos, or Files & Folders), unlock the iPhone, and try again. Nothing was deleted from the iPhone."
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.privacySettingsURL) }
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
        guard !prefs.quiet else { return }
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
