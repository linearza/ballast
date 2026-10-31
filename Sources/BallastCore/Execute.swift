import Foundation

public enum StepOutcome: Sendable, Equatable {
    case done
    case skipped(String)
    case failed(String)
    /// A `copyToTerminal` step: shown to the user, never run.
    case shown

    var label: String {
        switch self {
        case .done: "done"
        case .skipped: "skipped"
        case .failed: "failed"
        case .shown: "shown"
        }
    }
}

public struct StepResult: Sendable {
    public var step: Step
    public var outcome: StepOutcome
}

public enum PermissionProblem: Error {
    case fullDiskAccess(URL)
}

/// Runs a confirmed plan step by step, checking each item again first, and logs what happened.
public final class Executor: Sendable {
    let env: Environment
    let logURL: URL
    /// Copies files off an iPhone and deletes them there; nil where nothing can reach one.
    let iphone: (any IPhoneMediaTransfer)?
    static let commandTimeout: Duration = .seconds(600)
    public static let needsFullDiskAccess = "Needs Full Disk Access"

    public init(env: Environment, logURL: URL, iphone: (any IPhoneMediaTransfer)? = nil) {
        self.env = env
        self.logURL = logURL
        self.iphone = iphone
    }

    public func run(_ plan: Plan, provider: any Provider, items: [Item], pins: Pins,
                    progress: @Sendable (StepResult) -> Void) async -> [StepResult] {
        var results: [StepResult] = []
        let ids = Set(plan.steps.compactMap(\.itemID))
        let planned = items.filter { ids.contains($0.id) }
        let refusals = planned.isEmpty ? [:] : await provider.recheck(planned, env: env, pins: pins)
        var failed = Set<String>()
        for step in plan.steps {
            let outcome: StepOutcome
            if let id = step.itemID, let refusal = refusals[id] {
                outcome = .skipped(refusal.reason)
            } else if let id = step.itemID, failed.contains(id) {
                // An app's leftovers mustn't go when the app itself stayed.
                outcome = .skipped("An earlier step failed")
            } else {
                outcome = await perform(step.kind)
            }
            if case .failed = outcome, let id = step.itemID { failed.insert(id) }
            let result = StepResult(step: step, outcome: outcome)
            log(result)
            progress(result)
            results.append(result)
        }
        return results
    }

    func perform(_ kind: StepKind) async -> StepOutcome {
        switch kind {
        case .command(let argv):
            return outcome(await env.runner.run(argv, timeout: Self.commandTimeout))
        case .shell(let script):
            return outcome(await env.runner.shell(script, timeout: Self.commandTimeout))
        case .trash(let urls):
            let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) || isSymlink($0) }
            guard !present.isEmpty else { return .skipped("Already gone") }
            if present.contains(where: isProtected) { return .failed(Self.protectedPath) }
            for url in present {
                if let why = ownedByAnotherUser(url) { return .failed(why) }
                do { try env.trash(url) } catch { return failure(error, url) }
            }
            return .done
        case .truncate(let url):
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                return .done
            } catch { return failure(error, url) }
        case .unloadLoginItem(let label, let plist):
            let r = await env.runner.run(["launchctl", "bootout", "gui/\(getuid())/\(label)"], timeout: .seconds(30))
            let notLoaded = ["No such process", "Could not find", "not loaded"].contains { r.stderr.contains($0) }
            if !r.ok && !notLoaded { return outcome(r) }
            guard FileManager.default.fileExists(atPath: plist.path) else { return .done }
            do { try env.trash(plist) } catch { return failure(error, plist) }
            return .done
        case .copyToTerminal:
            return .shown
        case .moveFromIPhone(let udid, let files, let folder):
            return await moveFromIPhone(udid: udid, files: files, to: folder)
        }
    }

    /// Copies each file to `folder`, and deletes it from the iPhone only if the copy is the size the phone reports.
    /// A file whose copy doesn't check out stays on the phone, and the bad copy is removed.
    func moveFromIPhone(udid: String, files: [IPhoneFileRef], to folder: URL) async -> StepOutcome {
        guard let transfer = iphone else { return .failed("Ballast can't reach the iPhone's camera roll") }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return failure(error, folder) }
        var problems: [String] = []
        var failed = false
        for file in files {
            let name = file.name
            let copy = uniqueURL(in: folder, name: name)
            do {
                let reported = try await transfer.download(udid: udid, file: file, to: copy)
                let actual = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int64) ?? -1
                // The copy has to be the size the scan saw and the size Image Capture reports.
                guard file.bytes > 0, actual == file.bytes, actual == reported else {
                    try? FileManager.default.removeItem(at: copy)
                    problems.append("\(name) stays on the iPhone: the copy is \(max(actual, 0)) bytes, the iPhone says \(file.bytes)")
                    continue
                }
                do { try await transfer.delete(udid: udid, file: file) } catch {
                    problems.append("\(name) is copied to \(folder.lastPathComponent), but couldn't be deleted from the iPhone: \(error.localizedDescription)")
                    failed = true
                }
            } catch {
                try? FileManager.default.removeItem(at: copy)
                problems.append("\(name): \(error.localizedDescription)")
                failed = true
            }
        }
        if problems.isEmpty { return .done }
        let why = problems.joined(separator: "\n")
        return failed ? .failed(why) : .skipped(why)
    }

    /// `name`, or `name 2.ext`, `name 3.ext` when that file is already there.
    func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appending(path: name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func outcome(_ r: CommandResult) -> StepOutcome {
        if r.ok { return .done }
        let last = r.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
            ?? r.stdout.split(whereSeparator: \.isNewline).last.map(String.init)
        return .failed(last ?? "Exited with status \(r.status)")
    }

    func failure(_ error: Error, _ url: URL) -> StepOutcome {
        isPermission(error) ? .failed(Self.needsFullDiskAccess) : .failed(error.localizedDescription)
    }

    public static let protectedPath = "Ballast never removes this folder: macOS or your personal files depend on it"

    /// A last line of defence, whatever a provider asks for: never the home folder or anything above it,
    /// your personal folders, macOS's own folders, or keys and passwords.
    func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = env.home.standardizedFileURL.resolvingSymlinksInPath().path
        if home == path || home.hasPrefix(path.hasSuffix("/") ? path : path + "/") { return true }
        let exact = ["Documents", "Desktop", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications",
                     "Library/Application Support", "Library/Preferences", "Library/Caches", "Library/Containers",
                     "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Messages",
                     "Library/Photos", ".config", ".local", ".local/share", ".cache"].map { env.path($0).path }
            + ["System", "Library", "Applications", "Users", "usr", "usr/local", "usr/local/bin", "bin", "sbin", "private", "etc",
               "var", "opt", "opt/homebrew", "Volumes", "Library/Java/JavaVirtualMachines", "Library/Developer"].map { env.system($0).path }
        if exact.contains(path) { return true }
        let inside = [".ssh", ".gnupg", "Library/Keychains"].map { env.path($0).path }
            + ["System", "usr/bin", "usr/sbin", "usr/lib", "bin", "sbin", "private/etc", "Library/Keychains"].map { env.system($0).path }
        return inside.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public static let ownedByAnotherUser = "Installed for all users. Move it to the Trash in Finder, which asks for your password"
    public static let readOnlyParent = "Its folder is read-only. Move it to the Trash in Finder"

    /// Moving needs write access to the parent folder, and to a folder itself. Without it, the item belongs to
    /// another user (often root: App Store apps, Xcode), which Full Disk Access doesn't change.
    /// A read-only folder of your own (Go's module cache) is made writable first.
    /// EPERM is left alone: that's macOS privacy protection, which Full Disk Access does fix.
    func ownedByAnotherUser(_ url: URL) -> String? {
        var isDir: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue && !isSymlink(url)
        var st = stat()
        if isFolder, access(url.path, W_OK) != 0, stat(url.path, &st) == 0, st.st_uid == getuid() {
            chmod(url.path, st.st_mode | S_IWUSR)
        }
        for dir in [url.deletingLastPathComponent()] + (isFolder ? [url] : []) where access(dir.path, W_OK) != 0 && errno == EACCES {
            return stat(dir.path, &st) == 0 && st.st_uid == getuid() ? Self.readOnlyParent : Self.ownedByAnotherUser
        }
        return nil
    }

    func isPermission(_ error: Error) -> Bool {
        if error is PermissionProblem { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermission(underlying) }
        return false
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func log(_ r: StepResult) {
        let detail: String
        switch r.outcome {
        case .skipped(let why), .failed(let why): detail = why
        default: detail = r.step.kind.display
        }
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " | ") }
        let line = [ISO8601DateFormatter().string(from: env.now()), r.outcome.label, clean(r.step.title), clean(detail)]
            .joined(separator: "\t") + "\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
