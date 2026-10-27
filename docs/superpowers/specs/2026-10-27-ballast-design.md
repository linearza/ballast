# Ballast — design

A native macOS menu bar app that shows where disk space goes in the terms a developer thinks in ("RVM rubies: 9.8 GB, 10 versions", "Docker: 42 GB"), and removes what isn't needed the way the owning tool would.

## Why

On 2026-10-27 the disk hit 2.6 GB free. macOS Storage settings said "Developer" and "System Data", which doesn't help. Getting back to 113 GB free took an afternoon of `du`, judgement and tool-specific commands:
- Docker's 60 GB image lived outside the app, and trashing the app freed none of it.
- Six of ten Ruby versions weren't pinned by any project.
- 76 git worktrees belonged to merged PRs.
- Postgres 13 data was orphaned after its formula was uninstalled, and its login item was still trying to start it.

Ballast does that work in one place.

## Goals

1. **Insight first.** A breakdown by concern (tool, runtime, cache, project leftovers, data), each with its size, item count and how much is safely reclaimable. No "Other".
2. **Know what's in use.** Mark items that are defaults, pinned by a project, running, or recently used, so the unused ones stand out.
3. **Remove properly.** Prune unused versions, or uninstall a tool completely including its leftovers (data folders, login items, command-line links). Use the tool's own command where one exists.
4. **Light.** Lives in the menu bar and idles near zero CPU. Target under ~50 MB of memory when idle. A full window opens on demand.
5. **Permissions only when needed.** No Full Disk Access or folder-access prompts at launch or during a normal scan. Ballast asks at the moment an action needs it, for example measuring or deleting inside a protected folder.

## Non-goals (v1)

- A generic duplicate-file finder or treemap of the whole disk.
- Cleaning macOS system areas (SIP-protected locations, `/System`, OS update snapshots). These are explained, not touched.
- A privileged helper. Steps that need `sudo` are shown as a command to copy and run in Terminal.
- App Store distribution or notarisation. It's built for personal use and signed ad hoc (see Decisions).

## Anti-goals (a failure even if it works)

- Deleting anything without first showing exactly what will happen: the paths or command, the size, and the risk.
- Silently removing something that is in use or pinned. That stays possible, but only behind an explicit warning.
- `rm -rf` on things a tool manages (Ruby or Node versions, Homebrew packages, Ollama models, git worktrees) when the tool has its own removal command.
- Permanent deletion of files without the Trash in between. Files go to the Trash; only a tool's own command deletes directly.
- Asking for broad permissions up front, or prompting during a background scan.
- Being heavy: constant background disk walking, a resident process holding item lists, or Electron.

## Shape

### Menu bar popover
- Free space, shown as a bar and a number, with a warning colour below 10%.
- "Safe to reclaim: N GB": the total of items marked Regenerable.
- The five biggest concerns, with sizes.
- The Trash's size, with an Empty Trash button, since items Ballast moves to the Trash only free space once it's emptied.
- Last scanned time, Scan now, Open Ballast.

### Main window
- **Sidebar:** concerns grouped into sections, each showing its size.
  - Developer toolchains
  - Containers and VMs
  - Project leftovers
  - Caches
  - Local databases
  - AI models
  - Apps
  - Large personal files
  - Other dev data
- **Detail:** one concern's items. Each shows its size and status badges: `default`, `pinned by pipe, houston`, `running`, `merged PR`, `uncommitted changes`, `orphaned`, `last used 2023`. Each also carries a risk badge.
- **Risk levels:**
  - Regenerable (green): comes back by itself or with an install.
  - Review (amber): probably unused, but your call.
  - Your data (red): can't be recreated.
- **Selecting and removing:** checkboxes, with "Select safe" choosing the green, unused items. An action bar reads "Remove 9 items · 6.3 GB".
- **Confirmation sheet:** lists every step, in plain words with the exact command or path, and warns about anything in use. After a run, it shows per-item results and any errors.
- **Locked items:** where Ballast couldn't look without permission, it says so ("Locked: macOS protects this folder. Measure…"). It never guesses those sizes.

### Settings
- Project roots (default `~/Projects`), used for pins and project leftovers.
- Background rescan interval (off, 6 h or 24 h; default 24 h).
- Low-space notification threshold (default 10% free).
- Launch at login.

## Concerns (v1)

Each concern is a provider that answers four questions:
1. Is the tool present?
2. What are its items, and their sizes?
3. Which items are in use, and why?
4. What actions are there for each item?

| Concern | Items | In use when | Actions |
|---|---|---|---|
| Ruby (RVM, rbenv, asdf) | Versions, with their gems; RVM `src`/`archives` | Default version; pinned by `.ruby-version`, `.tool-versions` or `Gemfile` under the project roots | `rvm remove <v> --gems` / `rbenv uninstall -f` / `asdf uninstall ruby`; `rvm cleanup all`; uninstall the manager completely |
| Node (nvm, fnm, Volta, asdf) | Versions | Default alias; pinned by `.nvmrc`, `.node-version`, `.tool-versions` or `package.json` `engines`/`volta` | `nvm uninstall` etc.; `nvm cache clear` |
| Python (pyenv, venvs) | Versions; `~/.venvs`, project `.venv` | Pinned by `.python-version` | `pyenv uninstall -f`; trash a venv |
| Homebrew | Package versions; download cache; logs in `var/log`; data dirs in `var/` (Postgres, Redis, MySQL) | Package installed; service running | `brew cleanup --prune=all`; `brew autoremove`; empty a log in place if its service is running (truncate, never delete); trash an orphaned data dir |
| Xcode and simulators | Xcode.app (with version); DerivedData; Archives; iOS DeviceSupport; simulator devices and runtimes; CoreSimulator caches | `xcode-select -p` points at that Xcode | `xcrun simctl delete unavailable/all`, `simctl runtime delete`; trash caches; removing Xcode first shows the `sudo xcode-select -s /Library/Developer/CommandLineTools` step to copy, and is blocked until `xcode-select -p` no longer points inside it |
| Docker | Desktop data (`~/Library/Containers/com.docker.docker`, sized by allocated blocks); images, volumes and build cache when the daemon is running | Daemon running | `docker system prune` variants; full uninstall: the bundled uninstaller if present, else trash the app, data, group container, `~/.docker` and `/usr/local/bin` links pointing into Docker.app; the root-owned helpers in `/Library` are shown as a sudo command |
| Project leftovers | `node_modules` per project; git worktrees | Project touched (last commit, or modified) within N days (default 60); worktree has uncommitted changes, unpushed commits or an open PR (PR state from `gh pr list --state all` when `gh` is signed in; otherwise a branch deleted on the remote counts as merged) | Trash `node_modules`; `git worktree remove` (refuses if dirty), then `git worktree prune` |
| Package caches | npm, pnpm store, Yarn (classic and Berry), pip, Cargo, Go, CocoaPods, Gradle | Never; always Regenerable | `npm cache clean --force`, `pnpm store prune`, `yarn cache clean`, `pip cache purge`, … ; trash the folder as a fallback |
| App caches | Top entries of `~/Library/Caches`, with app names where known (Playwright, Cypress, Spotify, TypeScript, updater "ShipIt" leftovers) | The owning app is running: warn, still allowed | Trash the folder |
| Local databases | Postgres clusters (with per-database sizes when the server answers); orphaned clusters (formula gone); MySQL and Redis data | Cluster's server running | Orphaned cluster: trash it and remove its login item. Running ones: insight only |
| AI models | Ollama models; Hugging Face cache; whisper models; LM Studio | Ollama server running (warn) | `ollama rm` when the server is up; otherwise trash the model files; full Ollama uninstall (app, formula, `~/.ollama`, caches) |
| Apps | `/Applications` and `~/Applications` by size, with last opened (`kMDItemLastUsedDate`) | Running | Uninstall: trash the app plus its known leftovers (Application Support, Caches, Containers, Preferences, LaunchAgents matched by bundle id) |
| Large personal files | Files over 500 MB in Documents, Downloads, Desktop and Movies | Never auto-selected; always Your data | Reveal in Finder; move to Trash |
| Other dev data | GitHub Actions runner folders, Cursor and VS Code workspace storage, Claude VM bundles | — | Insight, Reveal and Trash. Their apps' own clean-up is preferred and named in the hint |

Leftover login items are found as `~/Library/LaunchAgents/*.plist` whose program no longer exists. They're reported under their concern (e.g. Homebrew → `homebrew.mxcl.postgresql@13`), unloaded with `launchctl bootout`, then trashed.

## Permissions

- **Normal scan:** reads only what needs no prompt. That's the home folder's dot-directories, `~/Library/Caches`, `~/Library/Developer`, `/opt/homebrew` and `/Applications`.
- **Documents, Downloads, Desktop:** "Large personal files" isn't scanned until the user opens that concern and presses Scan. That triggers macOS's own one-time folder prompt.
- **Protected locations** (`~/Library/Containers/<other app>` and `~/Library/Group Containers`): shown as Locked with a Measure button. If measuring or deleting fails with a permission error, a sheet explains Full Disk Access and opens the right System Settings pane.
- **Background scans:** never touch protected or prompting locations, and never prompt.
- **Running commands:** tool commands run as the user via `Process`, with the user's login-shell `PATH` resolved once (`zsh -lc 'echo $PATH'`), since a GUI app doesn't inherit it. RVM and nvm are shell functions, so they're run inside `zsh -lc` with their init script sourced.

## Measuring

- **Allocated size, not apparent size.** A sparse disk image (Docker.raw: 60 GB apparent, 42 GB allocated) is counted by what it really uses. Hard links are counted once.
- **Directory walking:** concurrent, low priority (`.utility`), skipping symlinks and not crossing volumes.
- **Freshness:** results are cached per concern with their scan time, and cache folders get a short time-to-live.
- **Persistence:** only a small summary (per-concern totals, scan time) is saved, to `~/Library/Application Support/Ballast/summary.json`, so the popover opens instantly. Item lists are rebuilt when the window opens, and released when it closes.
- **Free space:** from `volumeAvailableCapacityForImportantUsage`, matching what Finder shows.

## Actions and safety

- **Plans before actions.** An action is described as a plan: steps, each with a kind (tool command, move to Trash, truncate, unload login item, copy-to-Terminal), its exact target and its expected size. The plan is shown before anything runs.
- **Refusals before warnings.** Hard refusals come first and can't be overridden: Xcode while selected by `xcode-select`, a worktree with uncommitted changes. Then warnings: in use, pinned.
- **Execution:** sequential, one plan at a time, with live progress. After a run, the affected concerns are rescanned and the real amount freed is shown.
- **History:** every run is written to `~/Library/Logs/Ballast/actions.log`, with time, step, command and result.

## Decisions (made by the builder; open to change)

- **Name:** Ballast.
- **Distribution:** personal use. Built with SwiftPM and the Command Line Tools for Xcode 27. The installed 16.1 tools fail to build any Swift package because stale `.private.swiftinterface` files from an older install are left in `ManifestAPI`. A clean reinstall of the tools is a prerequisite. A script assembles `Ballast.app` (`LSUIElement`, no Dock icon), signs it ad hoc and copies it to `~/Applications`. No Xcode project and no notarisation.
- **Platform:** minimum macOS 14 (Observation, `MenuBarExtra(.window)`, `SMAppService`).
- **Swift package targets:**
  - `BallastCore`: providers, measuring, in-use detection, plans. No UI.
  - `Ballast`: the SwiftUI app.
- **Tests:** unit tests run on fixture directory trees in a temporary folder, plus a fake command runner. They cover sizing, pins, risk and plan generation. No test ever deletes outside its temp folder.
- **Design:** standard macOS look (SF Symbols, system materials, light and dark). Colour only for risk and the free-space bar.

## Left to the builder

- Exact layout, spacing and iconography.
- Which provider details make v1 and which wait. Order: Ruby, Node, Homebrew, Docker, Xcode, Project leftovers, Package caches, App caches, AI models, Apps, Databases, Large files, Other.
- How background rescans are scheduled (a timer while running is fine).
