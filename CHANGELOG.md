# Changelog

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
