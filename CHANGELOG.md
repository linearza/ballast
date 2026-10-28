# Changelog

## 0.3.1 — 2026-10-28

- **iCloud Drive:** large files in a Desktop or Documents folder synced with iCloud are marked *in iCloud*, and removing them needs **I understand**, because it removes them from every device.
- **Python:** removing a Python version names the pipx apps and Poetry, Pipenv or Hatch environments built on it.
- **RVM:** *Uninstall RVM completely* names the Rubies you use by default or projects pin.
- **Apps:** background helpers an app left in `~/Library/LaunchAgents` are stopped before they go to the Trash.
- **pnpm:** the pnpm store now shows only what `pnpm store prune` frees, the packages no project links to, instead of the whole store.
- **Project leftovers:** build folders under 1 MB are no longer listed.
- **Login items:** two leftover login items with the same name no longer clash.
- `make notarize` signs and notarises a release, for when there's a Developer ID to sign with.
- New screenshots, including Safe to reclaim.

## 0.3.0 — 2026-10-28

Ballast now guards harder against removing something you'll regret, especially if you're not sure what an item is.

- **Confirmation matches the stakes.** Routine clean-ups still confirm with Return. Review items and warnings need a click. Anything that can lose your work (your data, a version you use or a project pins, a running or unpushed worktree, Docker volumes, an app's saved data, database files, uninstalling Docker or Ollama) is listed under **Read this first**, and Remove stays off until you tick **I understand**.
- **Each step says whether it can be undone:** put back from the Trash, deleted for good (tool commands), or a command Ballast won't run for you.
- **Protected folders.** Ballast refuses to remove your home folder, its standard folders (Documents, Desktop, Downloads, Library and others), SSH and GPG keys, Keychains and macOS's own folders, whatever a scan suggests.
- **Removing an app** now says when its saved data (Application Support, Containers) goes with it.
- **`brew autoremove`** is now *Review*: it can remove formulae you use directly that came in as dependencies.
- **Build folders tracked by git** (a committed `Pods` or `dist`) are no longer offered as leftovers.
- **Safe to reclaim** opens a view of every item it counts, grouped by tool, with a button to review and remove each group. It's at the top of the sidebar and in the menu.
- **Empty Trash works again.** Ballast now declares why it controls Finder, so macOS asks instead of refusing. If you declined, it offers to open the right Settings pane. The confirmation says it removes everything in the Trash, and Return cancels.

## 0.2.0 — 2026-10-28

Ballast now recognises far more of the tools developers use.

- **Version managers:** chruby and frum for Ruby; n and nodenv for Node; uv-installed Pythons, conda environments, pipx apps and Poetry, Pipenv and Hatch virtualenvs.
- **Other languages:** a new section for Java (SDKMAN and installed JDKs), Go (goenv and `~/sdk`), Rust toolchains (rustup), Elixir, PHP and any tool installed with asdf or mise. Projects can pin these with `.java-version`, `.go-version`, `rust-toolchain.toml`, `.tool-versions` or `mise.toml`.
- **Project build output:** besides `node_modules`, idle projects' `target`, `.venv`, `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.angular`, `Pods`, `.gradle`, `_build`, `deps` and `.dart_tool` folders. `build` and `dist` in JavaScript projects are listed for review.
- **Caches:** Bun, Deno, uv, Poetry, conda packages, Go modules, SwiftPM, Carthage, Maven, Ivy, sbt, Coursier, NuGet, Composer, Bundler and Electron.
- **Containers and VMs:** Colima, Lima, minikube, Podman and Rancher Desktop machines, plus Parallels and VMware virtual machines. OrbStack and UTM are shown but left alone.
- **Xcode and Android:** watchOS, tvOS and visionOS device support, simulator logs and Xcode documentation; Android system images, NDKs and emulators.
- **Databases:** Postgres.app and DBngin, and databases are found without Homebrew too.
- **AI models:** GPT4All, Jan, llama.cpp, DiffusionBee and PyTorch Hub models.
- **AI tools and editors:** a new section for Cursor, VS Code, Windsurf and Claude app caches and old workspace data, old Claude Code versions, and Claude Code history for projects whose folder is gone. Items of a running editor aren't removed.
- Read-only folders you own, such as Go's module cache, can now be moved to the Trash. When the folder an item is in is read-only, Ballast says so instead of asking for Full Disk Access.
- The idle-time setting now covers all project build output, not only `node_modules`.

## 0.1.1 — 2026-10-27

Fixes from a security and feature review.

- Ollama: a model manifest can only point at files inside Ollama's own blobs folder.
- Databases started without `brew services` (with `pg_ctl` or `mysqld`) now count as running, so Ballast won't remove their data.
- Login items whose program is on a disk that isn't plugged in are no longer listed as leftovers.
- Apps installed for all users, such as App Store apps and Xcode, now say to move them to the Trash in Finder. Before, Ballast wrongly asked for Full Disk Access.
- When one step for an item fails, its later steps are skipped, so an app's settings stay if the app itself couldn't be removed.
- Apple's App Store apps (Pages, Numbers, Keynote) can be removed. Apps that ship with macOS still can't.
- "RVM downloads and sources" now runs `rvm cleanup archives` and `rvm cleanup sources` instead of `rvm cleanup all`, which also removed gem sets and logs.
- Git worktrees that use relative paths (`worktree.useRelativePaths`) are found again.
- Pressing Remove twice no longer runs the plan twice.
- The update check only links to release pages on github.com.
- mise: Node, Ruby and Python versions installed with mise, with mise's global version as the default and `mise.toml` pins respected.
- Xcode and Docker Desktop show when they're running, with a warning before removing them.
- A notification when a new version of Ballast is out, once per version. Clicking it opens the release page. Ballast now also checks while it stays open, not only when it starts.

## 0.1.0 — 2026-10-27

First release.

- Menu bar icon with free space, last scan time and the biggest things you could clean up.
- Main window that groups what's using your disk into toolchains, containers, project leftovers, caches, databases, AI models, apps and large files, with sizes and risk levels.
- Knows which Ruby, Node and Python versions your projects pin and never offers to remove those.
- Finds idle `node_modules` and git worktrees whose pull request is merged.
- Preview of every step before anything runs, a re-check just before acting, and files moved to the Trash rather than deleted.
- Uses each tool's own uninstall command where there is one (Homebrew, Docker, Ollama, git, simctl).
- Asks for Full Disk Access only for the protected items that need it, and shows `sudo` commands for you to run instead of running them.
- Background rescans, a low-space notification, launch at login and a daily check for new releases.
