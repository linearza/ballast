import Foundation

/// An iPhone plugged in by USB: what uses its storage, the biggest videos and photos in the camera roll, and its apps.
/// Talks to the phone through libimobiledevice (`idevice_id`, `ideviceinfo`, `ideviceinstaller`, `afcclient`), which
/// Ballast never installs. The camera roll is only listed this way; moving files off the phone goes through
/// `IPhoneMediaTransfer`, because deleting over AFC would leave the Photos library out of step.
public struct IPhoneProvider: Provider {
    /// Where moved files go: a folder per device inside it. Nil means `~/Pictures/From iPhone`.
    public var destination: URL?

    public init(destination: URL? = nil) { self.destination = destination }
    public let id = "iphone"
    public let title = "Connected iPhone"
    public let section = Section.iPhone
    public let symbol = "iphone"

    static let videoLimit: Int64 = 20_000_000
    static let fileLimit: Int64 = 50_000_000
    static let itemCap = 200
    static let paired = ["lockdown", "pair", "trust", "passcode", "password", "locked"]

    public func isPresent(_ env: Environment) async -> Bool {
        if case .none = await detect(env) { return false }
        return true
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        await snapshot(env).items
    }

    // MARK: - Detecting

    enum Detection: Equatable {
        case none, toolsMissing
        case devices([String])
    }

    func detect(_ env: Environment) async -> Detection {
        let r = await env.runner.run(["idevice_id", "-l"], timeout: .seconds(15))
        if r.status == 127 {
            // No libimobiledevice: still say so when an iPhone is on the USB bus.
            let usb = await env.runner.run(["system_profiler", "SPUSBDataType", "-json"], timeout: .seconds(30))
            return usb.ok && usbHasIPhone(usb.stdout) ? .toolsMissing : .none
        }
        let udids = parseDeviceIDs(r.stdout)
        return udids.isEmpty ? .none : .devices(udids)
    }

    /// Everything about the first connected iPhone (or `udid`), or why there's nothing to show.
    public func snapshot(_ env: Environment, udid wanted: String? = nil) async -> IPhoneSnapshot {
        switch await detect(env) {
        case .none:
            return IPhoneSnapshot(state: .notConnected)
        case .toolsMissing:
            return IPhoneSnapshot(state: .toolsMissing)
        case .devices(let udids):
            let udid = wanted.flatMap { udids.contains($0) ? $0 : nil } ?? udids[0]
            return await read(udid, env)
        }
    }

    func read(_ udid: String, _ env: Environment) async -> IPhoneSnapshot {
        let name = await env.runner.run(["ideviceinfo", "-u", udid, "-k", "DeviceName"], timeout: .seconds(20))
        guard name.ok else {
            let text = (name.stderr + name.stdout).lowercased()
            let state: IPhoneState = Self.paired.contains { text.contains($0) }
                ? .locked : .failed(name.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ideviceinfo exited with status \(name.status)")
            return IPhoneSnapshot(state: state, udid: udid)
        }
        var snap = IPhoneSnapshot(state: .ready, udid: udid)
        snap.name = firstTrimmedLine(name.stdout) ?? "iPhone"
        async let version = env.runner.run(["ideviceinfo", "-u", udid, "-k", "ProductVersion"], timeout: .seconds(20))
        async let usage = env.runner.run(["ideviceinfo", "-u", udid, "-q", "com.apple.disk_usage.factory"], timeout: .seconds(30))
        async let installed = env.runner.run(Self.listApps(udid), timeout: .seconds(60))
        snap.osVersion = firstTrimmedLine(await version.stdout)

        let appResult = await installed
        if appResult.status == 127 { snap.missingTools.append("ideviceinstaller") }
        let apps = appResult.ok ? parseApps(appResult.stdout) : []

        var files: [IPhoneMediaFile] = []
        let folders = await env.runner.shell(Self.afc(["ls -l /DCIM"], udid), timeout: .seconds(60))
        if folders.status == 127 { snap.missingTools.append("afcclient") }
        for folder in parseFolders(folders.stdout) {
            let r = await env.runner.shell(Self.afc(["ls -l /DCIM/\(folder)"], udid), timeout: .seconds(120))
            files += parseListing(r.stdout, folder: "/DCIM/\(folder)")
        }

        if let usageText = (await usage).okOutput {
            snap.storage = IPhoneStorage(diskUsage: usageText, apps: apps.reduce(0) { $0 + $1.bytes })
            snap.capacity = diskUsageValues(usageText)["TotalDiskCapacity"]
        }
        snap.media = IPhoneMediaTally(files)
        snap.items = mediaItems(files, udid: udid) + appItems(apps, udid: udid)
        return snap
    }

    static func listApps(_ udid: String) -> [String] {
        ["ideviceinstaller", "-u", udid, "list", "--user", "--xml", "-a", "CFBundleIdentifier", "-a", "CFBundleDisplayName",
         "-a", "StaticDiskUsage", "-a", "DynamicDiskUsage"]
    }

    /// A one-shot afcclient session: it reads its commands from stdin.
    static func afc(_ commands: [String], _ udid: String) -> String {
        "printf '\(commands.joined(separator: "\\n"))\\nexit\\n' | afcclient -u \(shellQuote(udid))"
    }

    // MARK: - Items

    func mediaItems(_ files: [IPhoneMediaFile], udid: String) -> [Item] {
        files.filter { $0.bytes >= Self.fileLimit || ($0.kind == .video && $0.bytes >= Self.videoLimit) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            .prefix(Self.itemCap)
            .map { file in
                Item(id: IPhoneItemID.media(udid, file.path), title: file.name,
                     detail: "\(file.kind.label) · \(file.dateLabel) · on iPhone", paths: [], bytes: file.bytes, risk: .yourData)
            }
    }

    func appItems(_ apps: [IPhoneApp], udid: String) -> [Item] {
        apps.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }.map { app in
            Item(id: IPhoneItemID.app(udid, app.bundleID), title: app.name,
                 detail: "App \(formatBytes(app.appBytes)) · Documents & Data \(formatBytes(app.dataBytes))",
                 paths: [], bytes: app.bytes, risk: .yourData)
        }
    }

    // MARK: - Plan

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var folders: [String: URL] = [:]
        for id in ids {
            guard let item = byID[id], let parsed = IPhoneItemID.parse(id) else { continue }
            switch parsed.kind {
            case .app:
                plan.steps.append(Step("Uninstall \(item.title)", .command(argv: ["ideviceinstaller", "-u", parsed.udid, "uninstall", parsed.rest]),
                                       bytes: item.bytes, itemID: item.id))
                plan.dangers.append("Uninstalling \(item.title) deletes everything it keeps on the iPhone. You can reinstall it from the App Store, but its data comes back only if the app syncs it somewhere.")
            case .media:
                if folders[parsed.udid] == nil { folders[parsed.udid] = await folder(for: parsed.udid, env) }
                plan.steps.append(Step("Move \(item.title) to your Mac", .moveFromIPhone(udid: parsed.udid, files: [IPhoneFileRef(path: parsed.rest, bytes: item.bytes)], to: folders[parsed.udid]!),
                                       bytes: item.bytes, itemID: item.id))
            }
        }
        if !folders.isEmpty {
            plan.dangers.append("If iCloud Photos is on, deleting from this iPhone deletes from iCloud and your other devices too. The copies on this Mac stay.")
        }
        return plan
    }

    /// `~/Pictures/From iPhone/<device name>/`, or the folder chosen in Settings.
    func folder(for udid: String, _ env: Environment) async -> URL {
        let r = await env.runner.run(["ideviceinfo", "-u", udid, "-k", "DeviceName"], timeout: .seconds(20))
        let base = destination ?? env.path("Pictures/From iPhone")
        return base.appending(path: folderName(firstTrimmedLine(r.stdout) ?? "iPhone"))
    }

    // MARK: - Recheck

    public func recheck(_ items: [Item], env: Environment, pins: Pins) async -> [String: Refusal] {
        var refusals: [String: Refusal] = [:]
        let connected: Set<String>
        if case .devices(let udids) = await detect(env) { connected = Set(udids) } else { connected = [] }
        var live: [String: [Item]] = [:]
        for item in items {
            guard let udid = IPhoneItemID.parse(item.id)?.udid, connected.contains(udid) else {
                refusals[item.id] = Refusal(itemID: item.id, reason: "iPhone disconnected")
                continue
            }
            live[udid, default: []].append(item)
        }
        for (udid, group) in live {
            let now = await snapshot(env, udid: udid)
            let fresh = Set(now.items.map(\.id))
            for item in group where !fresh.contains(item.id) {
                refusals[item.id] = Refusal(itemID: item.id, reason: now.state == .ready ? "Already gone" : now.state.message)
            }
        }
        return refusals
    }
}

// MARK: - Results

public enum IPhoneState: Sendable, Equatable {
    case notConnected, toolsMissing, locked, ready
    case failed(String)

    /// What to tell the user instead of a list.
    public var message: String {
        switch self {
        case .notConnected: "No iPhone connected"
        case .toolsMissing: "This build of Ballast doesn't include the iPhone tools. The download from the releases page does, or you can install them yourself with Homebrew."
        case .locked: "Unlock your iPhone and tap Trust"
        case .ready: ""
        case .failed(let why): "Couldn't read the iPhone: \(why)"
        }
    }
}

public struct IPhoneSnapshot: Sendable, Equatable {
    public var state: IPhoneState
    public var udid: String?
    public var name = "iPhone"
    public var osVersion: String?
    /// The whole flash storage, as sold (64 GB).
    public var capacity: Int64?
    public var storage: IPhoneStorage?
    public var media = IPhoneMediaTally([])
    /// libimobiledevice tools that were not found, so part of the picture is missing.
    public var missingTools: [String] = []
    public var items: [Item] = []

    public init(state: IPhoneState, udid: String? = nil) {
        self.state = state
        self.udid = udid
    }

    /// "iOS 18.6.2 · 64 GB".
    public var subtitle: String {
        [osVersion.map { "iOS \($0)" }, capacity.map(formatBytes)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// How the data volume's space is used, as far as a Mac can see over USB. Settings › General › iPhone Storage
/// reads more than this: app sizes there leave out caches iOS clears itself, and it counts data apps keep in
/// shared containers, Messages and System Data, none of which the phone reports to a Mac.
public struct IPhoneStorage: Sendable, Equatable {
    public var dataCapacity: Int64
    public var dataAvailable: Int64
    /// The system partition, which sits inside the capacity the bar shows.
    public var system: Int64
    public var photos: Int64
    /// Every user app's size plus its Documents & Data.
    public var apps: Int64

    public init(dataCapacity: Int64, dataAvailable: Int64, system: Int64, photos: Int64, apps: Int64) {
        self.dataCapacity = dataCapacity
        self.dataAvailable = dataAvailable
        self.system = system
        self.photos = photos
        self.apps = apps
    }

    /// Nil when the phone didn't report its capacity.
    public init?(diskUsage text: String, apps: Int64) {
        let v = diskUsageValues(text)
        guard let capacity = v["TotalDataCapacity"], let free = v["AmountDataAvailable"], capacity > 0 else { return nil }
        self.init(dataCapacity: capacity, dataAvailable: free, system: v["TotalSystemCapacity"] ?? 0,
                  photos: v["PhotoUsage"] ?? v["CameraUsage"] ?? 0, apps: apps)
    }

    public var free: Int64 { dataAvailable }
    /// The data volume's used space.
    public var used: Int64 { max(0, dataCapacity - dataAvailable) }
    /// What is used but not photos, apps or the system partition. Never negative.
    public var notVisible: Int64 { max(0, used - photos - apps - system) }

    public enum Part: String, Sendable, CaseIterable {
        case photos = "Photos & videos", apps = "Apps", system = "iOS", notVisible = "Not visible over USB", free = "Free"
    }

    public var parts: [(part: Part, bytes: Int64)] {
        [(.photos, photos), (.apps, apps), (.system, system), (.notVisible, notVisible), (.free, free)]
    }

    public static let notVisibleNote = "Messages, apps' shared data (Signal keeps its chats here), the rest of iOS and System Data. Settings › General › iPhone Storage on the phone breaks this down."
    public static let appsNote = "App sizes here include caches iOS can clear by itself, so some apps look bigger than they do in Settings."
}

/// Camera-roll photos and videos by type, counted over every file, not just the ones listed.
public struct IPhoneMediaTally: Sendable, Equatable {
    public var photoCount = 0, photoBytes: Int64 = 0
    public var videoCount = 0, videoBytes: Int64 = 0

    public init(photoCount: Int, photoBytes: Int64, videoCount: Int, videoBytes: Int64) {
        self.photoCount = photoCount
        self.photoBytes = photoBytes
        self.videoCount = videoCount
        self.videoBytes = videoBytes
    }

    public init(_ files: [IPhoneMediaFile]) {
        for f in files {
            switch f.kind {
            case .photo: photoCount += 1; photoBytes += f.bytes
            case .video: videoCount += 1; videoBytes += f.bytes
            case .other: break
            }
        }
    }

    public var isEmpty: Bool { photoCount + videoCount == 0 }

    /// "2,310 photos (HEIC, JPG) · 143 videos (MOV, MP4)".
    public var summary: String {
        func part(_ n: Int, _ bytes: Int64, _ noun: String, _ types: String) -> String {
            "\(n.formatted()) \(noun)\(n == 1 ? "" : "s") (\(formatBytes(bytes)), \(types))"
        }
        return [photoCount > 0 ? part(photoCount, photoBytes, "photo", "HEIC, JPG") : nil,
                videoCount > 0 ? part(videoCount, videoBytes, "video", "MOV, MP4") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public struct IPhoneApp: Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var appBytes: Int64
    public var dataBytes: Int64
    public var bytes: Int64 { appBytes + dataBytes }
}

public struct IPhoneMediaFile: Sendable, Equatable {
    public enum Kind: Sendable { case photo, video, other

        var label: String {
            switch self {
            case .photo: "Photo"
            case .video: "Video"
            case .other: "File"
            }
        }
    }

    /// On the phone: `/DCIM/110APPLE/IMG_0908.MOV`.
    public var path: String
    public var bytes: Int64
    public var date: Date

    public var name: String { String(path.split(separator: "/").last ?? "") }

    public var kind: Kind {
        switch (name as NSString).pathExtension.uppercased() {
        case "HEIC", "HEIF", "JPG", "JPEG", "PNG", "DNG", "GIF": .photo
        case "MOV", "MP4", "M4V": .video
        default: .other
        }
    }

    /// "29 Sep 2025", as the phone's clock wrote it.
    public var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }
}

/// Item ids: `iphone.<udid>.media.<DCIM path>` and `iphone.<udid>.app.<bundle id>`.
enum IPhoneItemID {
    enum Kind: String { case media, app }

    static func media(_ udid: String, _ path: String) -> String { "iphone.\(udid).media.\(path)" }
    static func app(_ udid: String, _ bundleID: String) -> String { "iphone.\(udid).app.\(bundleID)" }

    /// A UDID has no dots, so the first three dots split the id.
    static func parse(_ id: String) -> (udid: String, kind: Kind, rest: String)? {
        let parts = id.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "iphone", let kind = Kind(rawValue: String(parts[2])) else { return nil }
        return (String(parts[1]), kind, String(parts[3]))
    }
}

// MARK: - Moving files off the phone

public struct IPhoneTransferError: Error, LocalizedError, Equatable {
    public var message: String
    /// macOS (or the phone) refused access, so the Privacy & Security pane is worth opening.
    public var denied: Bool
    public var errorDescription: String? { message }

    public init(_ message: String, denied: Bool = false) {
        self.message = message
        self.denied = denied
    }
}

/// A camera-roll file as the scan saw it. Image Capture names its folders differently from the phone's
/// filesystem, so the file is found again by name and exact size, not by folder.
public struct IPhoneFileRef: Sendable, Equatable {
    /// On the phone's filesystem: `/DCIM/110APPLE/IMG_0908.MOV`.
    public var path: String
    public var bytes: Int64

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }

    public var name: String { String(path.split(separator: "/").last ?? "") }
}

/// Indices of the candidates with this name and exactly this size. One match is the file; none means it's gone;
/// more than one means Ballast can't tell which, so it touches none.
public func matchingFiles(name: String, bytes: Int64, in candidates: [(name: String, bytes: Int64)]) -> [Int] {
    candidates.indices.filter { candidates[$0].name == name && candidates[$0].bytes == bytes }
}

/// Image Capture writes a serial like `00008030-00C08282610402E` where the UDID is `00008030-000C08282610402E`:
/// the same digits with a zero dropped. Dashes and leading zeros of each part are ignored.
public func sameSerial(_ a: String, _ b: String) -> Bool {
    func normal(_ s: String) -> String {
        s.uppercased().split(separator: "-").map { String($0.drop { $0 == "0" }) }.joined()
    }
    let x = normal(a), y = normal(b)
    return !x.isEmpty && x == y
}

/// Copies camera-roll files off a phone and deletes them there. The real one uses ImageCaptureCore, which is
/// what Image Capture uses and keeps the Photos library consistent; the executor only decides *whether* to delete.
public protocol IPhoneMediaTransfer: Sendable {
    /// Copies the file at `path` (like `/DCIM/110APPLE/IMG_0908.MOV`) to `destination`, and returns the size
    /// in bytes the iPhone reports for it.
    func download(udid: String, file: IPhoneFileRef, to destination: URL) async throws -> Int64
    /// Deletes the file from the iPhone's camera roll.
    func delete(udid: String, file: IPhoneFileRef) async throws
}

// MARK: - Parsing

/// UDIDs from `idevice_id -l`, one per line.
func parseDeviceIDs(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
}

/// Whether `system_profiler SPUSBDataType -json` lists an iPhone anywhere in its tree.
func usbHasIPhone(_ json: String) -> Bool {
    guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return false }
    func walk(_ node: Any) -> Bool {
        if let dict = node as? [String: Any] {
            if let name = dict["_name"] as? String, name == "iPhone" { return true }
            return dict.values.contains { walk($0) }
        }
        if let array = node as? [Any] { return array.contains { walk($0) } }
        return false
    }
    return walk(root)
}

/// The whole-number `Key: value` lines of `ideviceinfo -q com.apple.disk_usage.factory`. The NANDInfo blob is ignored.
func diskUsageValues(_ text: String) -> [String: Int64] {
    var out: [String: Int64] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard let value = Int64(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) else { continue }
        out[key] = value
    }
    return out
}

/// User apps from `ideviceinstaller list --xml`: a plist array of dictionaries.
func parseApps(_ xml: String) -> [IPhoneApp] {
    guard let data = xml.data(using: .utf8),
          let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
    return list.compactMap { d in
        guard let bundle = d["CFBundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
        func bytes(_ key: String) -> Int64 { (d[key] as? NSNumber)?.int64Value ?? 0 }
        let name = (d["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundle
        return IPhoneApp(bundleID: bundle, name: name, appBytes: bytes("StaticDiskUsage"), dataBytes: bytes("DynamicDiskUsage"))
    }
}

/// Removes the colour and prompt escapes afcclient writes.
func stripANSI(_ s: String) -> String {
    s.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
}

/// Built on each use: a Regex value isn't Sendable, so it can't be a global.
private var listingLine: Regex<(Substring, Substring, Substring, Substring, Substring, Substring, Substring, Substring, Substring, Substring)> {
    /([-dl])[rwx-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) (.+)/
}

/// Folders of `ls -l /DCIM` (`110APPLE`), skipping `.MISC` and anything else that isn't a numbered camera folder.
func parseFolders(_ output: String) -> [String] {
    stripANSI(output).split(whereSeparator: \.isNewline).compactMap { line in
        guard let m = line.firstMatch(of: listingLine), m.1 == "d" else { return nil }
        let name = String(m.9).trimmingCharacters(in: .whitespaces)
        return name.wholeMatch(of: /\d{3}[A-Za-z0-9_]+/) == nil ? nil : name
    }.sorted()
}

/// Files of `ls -l <folder>`: `-rw-r--r-- 1 mobile mobile <size> DD Mon YYYY HH:MM:SS NAME`.
func parseListing(_ output: String, folder: String) -> [IPhoneMediaFile] {
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return stripANSI(output).split(whereSeparator: \.isNewline).compactMap { line in
        guard let m = line.firstMatch(of: listingLine), m.1 == "-", let bytes = Int64(m.2),
              let month = months.firstIndex(of: String(m.4)) else { return nil }
        let name = String(m.9).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let parts = DateComponents(year: Int(m.5), month: month + 1, day: Int(m.3), hour: Int(m.6), minute: Int(m.7), second: Int(m.8))
        guard let date = calendar.date(from: parts) else { return nil }
        return IPhoneMediaFile(path: "\(folder)/\(name)", bytes: bytes, date: date)
    }
}

/// A folder name from a device name: no slashes or colons, no leading dot.
func folderName(_ device: String) -> String {
    var name = device.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    while name.hasPrefix(".") { name.removeFirst() }
    return name.isEmpty ? "iPhone" : name
}

private func firstTrimmedLine(_ s: String) -> String? {
    s.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

private extension CommandResult {
    var okOutput: String? { ok ? stdout : nil }
}
