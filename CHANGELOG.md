# Changelog

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
