import BallastCore
import Dispatch
import Foundation

/// Watches memory for the menu bar icon. One cheap system reading every 30 s, plus the kernel's pressure events;
/// the per-app breakdown is only taken when `MemoryWatch` says it could matter. Nothing is written to disk.
@MainActor @Observable final class MemoryMonitor {
    var isRed = false
    var usedPercent: Int?
    var swapUsed: Int64 = 0
    var culprits: [Culprit] = []

    @ObservationIgnored private let reader: any MemoryReading
    @ObservationIgnored private var watch = MemoryWatch()
    @ObservationIgnored private var pressure = MemoryPressure.normal
    /// The sizes from the last breakdown, so the next one can say what grew. Replaced each time.
    @ObservationIgnored private var previous: [String: GroupReading] = [:]
    @ObservationIgnored private var ticking = false
    /// Each read takes the next number as it starts; a result older than one already shown is dropped.
    @ObservationIgnored private var started = 0
    @ObservationIgnored private var published = 0
    /// The newest read whose breakdown was applied; kept apart so a late forced breakdown isn't lost to a newer calm tick.
    @ObservationIgnored private var publishedBreakdown = 0
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private let queue = DispatchQueue(label: "za.co.linear.ballast.memory", qos: .utility)

    init(reader: any MemoryReading = LiveMemoryReader()) {
        self.reader = reader
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        t.setEventHandler { [weak self] in Task { @MainActor in await self?.tick() } }
        timer = t
        t.resume()

        let p = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        p.setEventHandler { [weak self, weak p] in
            guard let data = p?.data else { return }
            let level: MemoryPressure = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
            Task { @MainActor in
                self?.pressure = level
                await self?.tick()
            }
        }
        pressureSource = p
        p.resume()

        pressure = .normal
        Task { await tick() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// Opening the menu: always names the apps, however calm memory is.
    func refreshForMenu() async {
        await read(forceBreakdown: true)
    }

    /// A tick that arrives while the last read is still running is skipped.
    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        await read(forceBreakdown: false)
    }

    private func read(forceBreakdown: Bool) async {
        started += 1
        let generation = started
        let reader = reader
        guard let system = await Task.detached(priority: .utility, operation: { reader.system() }).value else { return }
        let now = Date()
        var groups: [MemoryGroup]?
        if forceBreakdown || watch.needsBreakdown(system: system, pressure: pressure, now: now) {
            groups = await Task.detached(priority: .utility) { groupProcesses(reader.processes()) }.value
        }
        publish(system: system, groups: groups, now: Date(), generation: generation)
    }

    private func publish(system: SystemMemory, groups: [MemoryGroup]?, now: Date, generation: Int) {
        if generation > published {
            published = generation
            watch.update(system: system, pressure: pressure, topGroupBytes: groups.map { $0.map(\.bytes).max() ?? 0 }, now: now)
            // Only touch observed properties when they change, so a calm tick wakes no views.
            if isRed != watch.isRed { isRed = watch.isRed }
            if usedPercent != system.usedPercent { usedPercent = system.usedPercent }
            if swapUsed != system.swapUsed { swapUsed = system.swapUsed }
        }
        // No breakdown this time, or an older one than already shown: keep the culprits and sizes as they are.
        guard let groups, generation > publishedBreakdown else { return }
        publishedBreakdown = generation
        let found = namedCulprits(groups, physical: system.physical, previous: previous, now: now)
        if culprits != found { culprits = found }
        previous = Dictionary(groups.map { ($0.id, GroupReading(bytes: $0.bytes, at: now)) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The property `culprits` hides BallastCore's function of the same name inside the class.
private func namedCulprits(_ groups: [MemoryGroup], physical: Int64, previous: [String: GroupReading], now: Date) -> [Culprit] {
    culprits(groups, physical: physical, previous: previous, now: now)
}
