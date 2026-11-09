# Ballast memory alerts: design

Status: awaiting owner approval. "Owner" marks what the owner decided. "Author's call" marks a choice made in writing this, which the owner can overturn.

## Why

On 2026-11-06 this Mac (32 GB of memory) reached 36.5 of 37.9 GB of swap and `loginwindow` crashed, ending the login session. The swap also took about 40 GB of disk that Ballast could not explain. Brave's renderers were the largest memory user in that morning's system log, and several vitest runs can each spawn 8+ node workers at about 4 GB each.

Nothing warned the owner while it built up. Activity Monitor can show it, but only if you already suspect something and go looking.

## What it does

When memory goes into the red, the Ballast menu bar icon changes. Opening the menu names what is causing it, says by how much, and offers to close it.

Two situations must be caught (owner):
- **A sudden spike:** for example several vitest processes pushing memory into the red. No single process may look alarming, so they are counted as a group.
- **A slow hog:** for example Brave holding 70% of memory through too many tabs. Nothing spikes, so this is detected by share of memory, not by growth.

## Goals

- The icon is the only alert (owner). No notifications, sounds or badges "for now".
- Flag the exact culprit, how much it uses, and offer to close it (owner).
- Show a % of current memory use with the alert (owner).
- Show and close whole groups, not individual processes (owner).
- Stay light (owner): Ballast's existing target of under about 50 MB idle and near-zero idle CPU holds with monitoring on.

## Non-goals

- Closing anything automatically, even in the red zone (author's call).
- History, charts or anything written to disk about memory use (author's call).
- Picking individual processes to close (owner chose groups).
- Replacing Activity Monitor: this names one or a few culprits, not every process.
- Reclaiming the swap file's disk space. Ballast can't do that; closing the culprit lets macOS shrink it over time.

## Anti-goals: it has failed if

- Monitoring makes Ballast itself a noticeable memory or CPU user.
- It offers to close a system process, or Ballast itself.
- Something closes without the owner confirming, or unsaved work is lost without warning.
- The icon stays changed on a healthy machine, or flickers, so the owner learns to ignore it.
- It states a growth figure it did not measure, or inflates memory by double-counting shared memory.

## Behaviour

### When the icon changes

Red means either (author's call on both):
- macOS reports memory pressure as critical or warning. Use the system's event (`DispatchSource.makeMemoryPressureSource`), not polling.
- A cheap periodic read of system memory shows one group holding at least 50% of physical memory, or used memory jumping sharply. The owner's example of 70% must trigger, so the threshold must be below it. The builder tunes the jump threshold by trying it, starting at about 25% of physical memory within 2 minutes.

Swap is shown as context in the headline when it's high, but is not its own trigger in this version (author's call): pressure normally rises first.

The icon returns to normal by itself when the condition clears. Use hysteresis (for example, stay red for at least 60 seconds and clear at a lower threshold than the trigger) so it doesn't flicker.

The icon is currently `scalemass`, or `scalemass.fill` on low disk space. Memory red needs a clearly different symbol and takes priority over low disk (author's call; the builder picks the symbol).

While red, the current memory use shows as a percentage right beside the icon in the menu bar, for example "87%" (owner asked for the % with the alert; placing it beside the icon is the author's call). The percentage goes away when the icon returns to normal, and it updates on the slow timer, not continuously. It uses the same definition as Activity Monitor's "Memory Used" (app, wired and compressed memory, as a share of physical memory), so the two agree.

Quiet mode hides the icon entirely today. In quiet mode this feature has no visible alert, and that stays as is; don't sample in quiet mode unless a window is open (author's call).

### What the menu shows

A block at the top of the existing menu, only while red, led by the current memory use ("Memory 87% used") and then the top culprit group, and up to two more if they are also significant. Examples of the content (exact wording is the builder's, plain and literal):

- "Brave · 22 GB · 69% of memory"
- "vitest · 8 processes · 31 GB · up 24 GB in 2 min"

Each row has a Close button. "By how much" (owner) means current size and share of memory, plus growth only when a previous reading exists to compare it to. No earlier reading means no growth figure, never a guess.

If nothing stands out (pressure is high but spread across many small groups), say so plainly rather than naming a false culprit.

The feature is menu-only for now: nothing is added to the main window (author's call).

### Grouping

- Anything inside an app bundle counts as that app, helpers included: Brave's renderer and GPU helpers are "Brave". Resolve by walking the executable path to the outermost `.app`, or by the responsible process if that proves more accurate.
- Other processes group by executable name, or for script runtimes by what's actually useful to the owner: vitest workers appear as `node`, so a builder must find a way to show "vitest" rather than "node" where it can (the parent command or argv), falling back to "node" and the working folder. Don't lump unrelated node processes under one Close button without saying so.

### Measuring

- Per-process memory comes from `proc_pid_rusage` `ri_phys_footprint`, not RSS. On 2026-11-06 summing nominal per-process figures gave 42 GB for Brave alone on a 32 GB machine, inflated by shared memory. Footprint is the same measure Activity Monitor's Memory column uses, and is far less inflated. Sums may still be approximate; the UI rounds accordingly.
- Native calls only; don't spawn `ps` or `top` for sampling.

### Lightweight by design

Two levels (owner asked for light; the structure is the author's call):
1. **Always on:** the pressure event (no polling) plus one system-wide memory read on a slow timer, starting at about 30 seconds.
2. **On demand:** the per-process breakdown runs only when level 1 sees something (pressure, a jump, or used memory high enough that a hog is possible) or when the menu opens.

Memory held: the latest per-group reading replaced each time, plus a small fixed-size window of system totals. Nothing grows over time and nothing goes to disk. Ballast takes the timer tolerance macOS offers so wakeups coalesce.

Trade-off accepted: a hog may be flagged a few minutes late, and a brief spike between readings can be missed. The pressure event covers the spikes that matter. If the target can't be met, slow the checks; don't move the target.

Measure Ballast's own idle memory and CPU with this on before and after, and report both numbers in the PR.

### Closing

Always through a confirmation (owner asked for "the option to close"; confirming is the author's call). Reuse the existing confirmation sheet's look. It lists what will close: the group's processes and their sizes (owner asked to see the group), and warns about unsaved work.

- **Apps:** `NSRunningApplication.terminate()`, a normal Quit, so they can save state and restore. If it hasn't quit after a while, say so and offer Force Quit as a separate, explicit choice.
- **Other processes:** `SIGTERM` to the group. On 2026-11-06 nine `tsx watch` processes ignored SIGTERM, so if any survive after a few seconds, offer Force Stop (`SIGKILL`) as a separate explicit choice.
- **Never offered:** processes owned by other users or root, Apple system processes (anything under `/System`, `/usr/libexec` and so on), and Ballast itself. These are still named if they are the cause, with no button and a short line saying macOS or the owner has to deal with it.
- **PID safety:** re-check that each PID still is the same process (start time and path) immediately before signalling, so a reused PID is never hit.
- Afterwards, re-measure and show the result, including anything that didn't close.

Ballast isn't sandboxed (`Resources/Ballast.entitlements` only has Apple Events), so signalling the user's own processes needs no new entitlement. Check this holds on a signed build.

## Where it fits

- `Sources/BallastCore/`: new pure logic (reading, grouping, red decision, hysteresis, close-eligibility) with samples passed in, so it's testable without real processes. Follows the `CommandRunner`-style seam already used.
- `Sources/Ballast/AppModel.swift`: holds state, follows existing async patterns.
- `Sources/Ballast/BallastApp.swift`: icon choice.
- `Sources/Ballast/Popover.swift`: the block.
- `Sources/Ballast/ConfirmSheet.swift`: existing sheet is built around `Provider`, `Plan` and `Item`, and those are disk concepts. Reuse its look; use a separate small sheet if adapting it would distort the disk flow (author's call).
- `Sources/Ballast/Screenshots.swift`: add a red-state screenshot, and update the README.

This builds on the current `main`. The branch `fix/trash-empty-and-size` also touches `Popover.swift` and `AppModel.swift` and isn't merged yet, so expect a small merge.

## Testing

- Unit tests with fixed samples: grouping (Brave helpers, vitest workers, unrelated node), threshold and hysteresis, no growth figure without a prior reading, system and own processes never closable, PID reuse refused.
- By hand on a real signed build: run a real memory hog and confirm the icon changes, the culprit is named correctly, Close works for an app and a CLI group, and the icon clears.

## Left to the builder

Exact copy, the symbol, layout within the 320 pt menu, final thresholds and timer intervals (within the rules above), how to name node-based tools, and how the sheet is shared.
