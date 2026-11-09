# Memory Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When memory goes red, the Ballast menu bar icon changes and shows a percentage, and the menu names the culprit group, how much it uses, and offers to close it.

**Architecture:** Pure decisions live in `BallastCore` and take samples as input, so they test without real processes. A thin live reader makes the native calls. `Sources/Ballast/MemoryMonitor.swift` owns the pressure event and slow timer and publishes state for the icon and menu.

**Tech Stack:** Swift, SwiftUI `MenuBarExtra`, Swift Testing (`@Suite`, `@Test`, `#expect`), libproc, Mach `host_statistics64`, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-11-06-memory-alerts-design.md`

## Global Constraints

- Icon only as the alert: no notifications, sounds or badges.
- Under about 50 MB idle and near-zero idle CPU with monitoring on. If not met, slow the checks; don't move the target.
- No `ps` or `top` for sampling; native calls only. No history and nothing about memory written to disk.
- Per-process size is `ri_phys_footprint` from `proc_pid_rusage`, never RSS.
- Never close automatically. Never offer to close system processes, other users' or root's processes, or Ballast itself.
- No growth figure without a measured earlier reading.
- `BallastApp` holds the model without `@State`, because the Command Line Tools lack that SwiftUI macro plugin on this SDK. Keep that pattern.
- Run `make test` to verify. It must report 0 failures.

## Review Focus

Each has its test in the owning task.

1. A process exits between listing and reading it: it's skipped, and the rest of the reading still works (Task 1).
2. An app nested in an app (`Brave Browser.app/.../Brave Browser Helper (Renderer).app`): it counts as the outermost app (Task 1).
3. Unrelated node processes in different folders: they're not put under one Close button (Task 1).
4. A group mixing the owner's and root's processes: Close covers only the owner's, and says so (Task 3).
5. A zero or missing physical memory reading: no division by zero, not red, no percentage (Task 2).

---

### Task 1: Read and group processes

**Files:**
- Create: `Sources/BallastCore/MemoryGroups.swift`
- Create: `Sources/BallastCore/MemoryReader.swift`
- Test: `Tests/BallastCoreTests/MemoryGroupsTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProcessSample: Equatable, Sendable { pid: Int32; startSeconds: UInt64; uid: UInt32; path: String?; args: [String]; cwd: String?; footprint: Int64 }`
  - `public struct MemoryGroup: Equatable, Sendable { id: String; name: String; processes: [ProcessSample]; bytes: Int64 }`
  - `public func groupProcesses(_ samples: [ProcessSample]) -> [MemoryGroup]`, largest first
  - `public struct SystemMemory: Equatable, Sendable { physical: Int64; used: Int64; swapUsed: Int64; var usedPercent: Int? }`
  - `public protocol MemoryReading: Sendable { func system() -> SystemMemory?; func processes() -> [ProcessSample] }`, and `public struct LiveMemoryReader: MemoryReading`

- [ ] **Step 1: Write the failing tests** in `MemoryGroupsTests.swift`, with a `sample(...)` helper:

```swift
@Test func helpersCountAsTheOutermostApp() {
    let p = "/Applications/Brave Browser.app/Contents/Frameworks/B.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/x"
    let g = groupProcesses([sample(pid: 1, path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", bytes: 10), sample(pid: 2, path: p, bytes: 5)])
    #expect(g.count == 1); #expect(g[0].name == "Brave Browser"); #expect(g[0].bytes == 15)
}
@Test func vitestWorkersShowAsVitest() {
    let w = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/vitest/dist/workers/forks.js"], cwd: "/r", bytes: 4)
    #expect(groupProcesses([w, w.with(pid: 2)])[0].name == "vitest")
}
@Test func unrelatedNodeStaysApart() {
    let g = groupProcesses([sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "a.js"], cwd: "/p/one", bytes: 1), sample(pid: 2, path: "/opt/node/bin/node", args: ["node", "b.js"], cwd: "/p/two", bytes: 1)])
    #expect(g.count == 2); #expect(Set(g.map(\.name)) == ["node · one", "node · two"])
}
@Test func plainToolsGroupByExecutable() { /* two /usr/local/bin/foo samples form one group named "foo" */ }
@Test func missingPathGroupsAsUnknown() { /* path nil: name "Unknown process", no crash */ }
@Test func percentHandlesZeroPhysical() { #expect(SystemMemory(physical: 0, used: 0, swapUsed: 0).usedPercent == nil) }
```

- [ ] **Step 2: Run** `make test`. Expected: compile failure, types not defined.

- [ ] **Step 3: Implement `groupProcesses` and `SystemMemory`.** Runtimes are `node`, `bun`, `deno`, `python`, `python3`, `ruby`. For these, a tool name comes from `node_modules/<tool>/` in any arg (the last such segment that isn't `.pnpm`); otherwise the group is `<runtime> · <last cwd component>`, and just `<runtime>` if there's no cwd. `usedPercent` is nil when `physical <= 0`, otherwise rounded and clamped to 0...100.

- [ ] **Step 4: Implement `LiveMemoryReader`.** `system()`: `host_statistics64(HOST_VM_INFO64)` with `used = (internal_page_count - purgeable_count + wire_count + compressor_page_count) * pageSize` to match Activity Monitor's Memory Used; `physical` from `ProcessInfo.physicalMemory`; `swapUsed` from sysctl `vm.swapusage`. `processes()`: `proc_listallpids`, then `proc_pidpath`, `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_pidinfo(PROC_PIDTBSDINFO)`. Fetch args (`KERN_PROCARGS2`) and cwd (`PROC_PIDVNODEPATHINFO`) **only** when the executable is a runtime, which keeps it cheap. A pid whose calls fail is skipped; add a test using a pid that doesn't exist (`LiveMemoryReader.sample(pid: Int32.max) == nil`), so make `sample(pid:)` internal.

- [ ] **Step 5: Add a live sanity test:** `LiveMemoryReader().processes()` contains the test's own pid with `footprint > 0`, and `system()?.usedPercent` is non-nil.

- [ ] **Step 6: Run** `make test`. Expected: 0 failures.

- [ ] **Step 7: Commit** `Read per-process memory and group it by app`.

### Task 2: Decide when memory is red

**Files:**
- Create: `Sources/BallastCore/MemoryWatch.swift`
- Test: `Tests/BallastCoreTests/MemoryWatchTests.swift`

**Interfaces:**
- Consumes: `SystemMemory`, `MemoryGroup` (Task 1)
- Produces:
  - `public enum MemoryPressure: Sendable { case normal, warning, critical }`
  - `public struct MemoryWatch: Sendable { public init(); public private(set) var isRed: Bool; public func needsBreakdown(system: SystemMemory, pressure: MemoryPressure, now: Date) -> Bool; public mutating func update(system: SystemMemory, pressure: MemoryPressure, topGroupBytes: Int64?, now: Date) }`
  - `public struct Culprit: Equatable, Sendable { group: MemoryGroup; share: Int; growth: Int64?; growthSeconds: Int? }`
  - `public func culprits(_ groups: [MemoryGroup], physical: Int64, previous: [String: GroupReading], now: Date) -> [Culprit]`
  - `public struct GroupReading: Equatable, Sendable { bytes: Int64; at: Date }`

Values: red on pressure warning or critical, top group at least 50% of physical, or used up by at least 25% of physical within 120 s. Clears only below 40% for the top group with normal pressure and no recent jump, and no sooner than 60 s after going red. The totals window holds at most 5 entries.

- [ ] **Step 1: Write the failing tests:**
  - `pressureGoesRed`, `critical` with low usage is red
  - `seventyPercentHogGoesRed`: a top group at 70% of physical with normal pressure is red (the owner's Brave example)
  - `fiftyPercentIsTheLine`: 49% isn't red, 50% is
  - `jumpGoesRed`: used rising 25% of physical across two readings 60 s apart is red, and the same rise over 300 s isn't
  - `staysRedAtLeastAMinute`: conditions clear after 30 s: still red; after 61 s: not red
  - `doesNotFlickerBetweenThresholds`: top group at 45% after being red stays red
  - `breakdownSkippedWhenCalm`: `needsBreakdown` is false at 30% used, normal pressure
  - `breakdownRunsWhenHogPossible`: true at 50% used or more, on non-normal pressure, or on a jump
  - `zeroPhysicalIsNeverRed`
  - `totalsWindowStaysBounded`: 1,000 updates keep at most 5 stored entries (expose the count internally)
  - `culpritsNeedAFifteenPercentShare`: up to 3 returned, and none below 15% of physical
  - `nothingStandsOut`: many small groups return `[]`
  - `noGrowthWithoutAnEarlierReading`: `growth == nil`
  - `growthOnlyWhenItGrew`: up by at least 1 GB gives `growth` and `growthSeconds`; a shrink gives nil

- [ ] **Step 2: Run** `make test`. Expected: compile failure.

- [ ] **Step 3: Implement `MemoryWatch` and `culprits`** with the values above as named constants at the top of the file.

- [ ] **Step 4: Run** `make test`. Expected: 0 failures.

- [ ] **Step 5: Commit** `Decide when memory is red and who is responsible`.

### Task 3: Decide what can be closed, and close it safely

**Files:**
- Create: `Sources/BallastCore/MemoryClose.swift`
- Test: `Tests/BallastCoreTests/MemoryCloseTests.swift`

**Interfaces:**
- Consumes: `ProcessSample`, `MemoryGroup`
- Produces:
  - `public enum CloseOption: Equatable, Sendable { case app(bundlePath: String, skipped: Int); case processes([ProcessSample], skipped: Int); case notOffered(String) }`
  - `public func closeOption(for group: MemoryGroup, myUID: UInt32, myPID: Int32) -> CloseOption`
  - `public protocol ProcessControl: Sendable { func identity(pid: Int32) -> (startSeconds: UInt64, path: String?)?; func signal(pid: Int32, _ sig: Int32) -> Bool }`, and `public struct LiveProcessControl: ProcessControl`
  - `public struct CloseOutcome: Equatable, Sendable { signalled: [Int32]; refused: [Int32] }`
  - `public func signalAll(_ samples: [ProcessSample], signal sig: Int32, control: any ProcessControl) -> CloseOutcome`
  - `public func survivors(_ samples: [ProcessSample], control: any ProcessControl) -> [ProcessSample]`

System paths: `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `/bin/`, `/usr/bin/`, `/Library/Apple/`. Apps in `/Applications` are closable, including Safari. A nil path isn't closable.

- [ ] **Step 1: Write the failing tests:**
  - `systemProcessNotOffered`: a `/usr/libexec/` group gives `.notOffered`
  - `otherUsersNotOffered`: a different uid gives `.notOffered`
  - `ballastNeverOffered`: a group containing `myPID` gives `.notOffered`
  - `appGroupClosesAsApp`: Brave with helpers gives `.app(bundlePath: "/Applications/Brave Browser.app", skipped: 0)`
  - `mixedGroupClosesOnlyMine`: 3 mine plus 1 root gives `.processes` of 3 with `skipped: 1`
  - `reusedPIDIsRefused`: a fake control returns a different `startSeconds`; `signalAll` doesn't signal it and lists it in `refused`
  - `goneProcessIsRefused`: identity nil gives `refused`, no signal
  - `survivorsListsTheStillRunning`

- [ ] **Step 2: Run** `make test`. Expected: compile failure.

- [ ] **Step 3: Implement.** `LiveProcessControl` uses the Task 1 libproc calls and `kill(2)`. The identity check happens immediately before each signal. `Darwin.SIGTERM` and `SIGKILL` are passed by the caller; this file never chooses to force.

- [ ] **Step 4: Run** `make test`. Expected: 0 failures.

- [ ] **Step 5: Commit** `Decide what can be closed and refuse reused PIDs`.

### Task 4: Monitor in the app, with the icon and percentage

**Files:**
- Create: `Sources/Ballast/MemoryMonitor.swift`
- Modify: `Sources/Ballast/AppModel.swift` (hold `let memory = MemoryMonitor()`, start it in `launch()`)
- Modify: `Sources/Ballast/BallastApp.swift` (the `MenuBarExtra` label)
- Modify: `Sources/BallastCore/MemoryWatch.swift`, `Tests/BallastCoreTests/MemoryWatchTests.swift` (`menuBarSymbol`)

**Interfaces:**
- Consumes: `MemoryReading`, `MemoryWatch`, `culprits`, `MemoryPressure`
- Produces:
  - `@MainActor @Observable final class MemoryMonitor { var isRed: Bool; var usedPercent: Int?; var swapUsed: Int64; var culprits: [Culprit]; func start(); func stop(); func refreshForMenu() async }`
  - `public func menuBarSymbol(memoryRed: Bool, lowSpace: Bool) -> String` (red: `memorychip.fill`, then `scalemass.fill`, then `scalemass`)

- [ ] **Step 1: Write the failing test** `menuBarSymbol`: memory red wins over low space; both other cases return the existing symbols. Run `make test`; expected compile failure, then implement it and re-run.

- [ ] **Step 2: Implement `MemoryMonitor`.** `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical])` on a background queue, plus a repeating 30 s timer with `tolerance` of 10 s. Each tick reads `system()` off the main actor, and calls `processes()` and `culprits` only when `needsBreakdown` says so, replacing the `[String: GroupReading]` map each time. `refreshForMenu()` always takes a breakdown. `stop()` cancels both. Don't start while `prefs.quiet` is true unless a window is open; restart when quiet is turned off.

- [ ] **Step 3: Change the label** to show `Image(systemName: menuBarSymbol(...))` and, only while red, `Text("\(percent)%")` beside it. Check it renders on a real build: `MenuBarExtra` labels may flatten an `HStack`, in which case use `Label`/a single `Text` with an image interpolation.

- [ ] **Step 4: Run** `make test` and `make build`. Expected: 0 failures, build complete.

- [ ] **Step 5: Commit** `Watch memory and show the alert in the menu bar`.

### Task 5: The menu block and closing

**Files:**
- Create: `Sources/Ballast/MemoryBlock.swift`
- Modify: `Sources/Ballast/Popover.swift` (block at the top of the menu while red; call `refreshForMenu()` on appear)
- Modify: `Sources/BallastCore/MemoryClose.swift`, `Tests/BallastCoreTests/MemoryCloseTests.swift` (`culpritLine`)

**Interfaces:**
- Consumes: `MemoryMonitor`, `Culprit`, `closeOption`, `signalAll`, `survivors`, `LiveProcessControl`
- Produces: `public func culpritLine(_ c: Culprit) -> String`; `struct MemoryBlock: View { let model: AppModel }`

- [ ] **Step 1: Write the failing tests** for `culpritLine`:

```swift
// "Brave Browser · 22 GB · 69% of memory"
// "vitest · 8 processes · 31 GB · up 24 GB in 2 min"
```
A single-process group omits the count; no growth means no "up" part. Use `formatBytes` for sizes, so assert against `formatBytes(...)` rather than literal strings if its rounding differs. Run, see them fail, implement, run again.

- [ ] **Step 2: Build `MemoryBlock`,** using Theme tokens: "Memory 87% used", swap in muted text when above 1 GB, then one row per culprit with a Close button. `.notOffered` shows its reason and no button. No culprits shows "Nothing stands out: memory is spread across lots of small processes."

- [ ] **Step 3: Implement closing with `NSAlert`,** the same way `emptyTrash()` already confirms, because a sheet can't hang off the menu's window. The alert lists the group's processes and sizes (up to 10, then "and N more"), warns about unsaved work, and mentions any `skipped` count. On confirm:
  - `.app`: `NSRunningApplication.terminate()`. If it's still running after 5 s, a second `NSAlert` offers Force Quit (`forceTerminate()`).
  - `.processes`: `signalAll(SIGTERM)`. After 3 s, `survivors`; if any remain, a second `NSAlert` offers Force Stop (`SIGKILL`).
  - Afterwards, `refreshForMenu()`, and report what didn't close in an alert.

- [ ] **Step 4: Run** `make test` and `make build`. Expected: 0 failures, build complete.

- [ ] **Step 5: Commit** `Name the culprit in the menu and offer to close it`.

### Task 6: Screenshots, docs and measuring the cost

**Files:**
- Modify: `Sources/Ballast/Screenshots.swift` (a red-state fixture and capture)
- Modify: `README.md`

- [ ] **Step 1: Add a red-state screenshot** with an invented culprit, rendered to the scratch directory first. If the run hangs, report it rather than skipping silently.

- [ ] **Step 2: Add a README paragraph** on the alert, what it can close, and what it never closes.

- [ ] **Step 3: Measure.** Build `make app`, run it for 10 minutes idle before and after this branch, and record `footprint <pid>` and CPU from `top -l 2 -pid <pid>` in the PR description. Expected: under about 50 MB and near-zero CPU. If not, lengthen the timer in `MemoryMonitor` and measure again.

- [ ] **Step 4: Hand-check list for the owner's signed build,** in the PR description: the icon and % appear under a real hog, the culprit is named correctly, Close works for an app and for a CLI group, the icon clears, and the % agrees with Activity Monitor.

- [ ] **Step 5: Run** `make test`. Expected: 0 failures. **Commit** `Document memory alerts and capture the red state`.
