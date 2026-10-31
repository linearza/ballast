import Foundation
import Testing
@testable import BallastCore

/// Stands in for ImageCaptureCore: writes `copyBytes` bytes per download, reports `reportedBytes`, and remembers deletes.
final class FakeTransfer: IPhoneMediaTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var _deleted: [String] = []
    private var _downloaded: [String] = []
    /// Nil means "the size the scan saw".
    var copyBytes: Int64?
    var reportedBytes: Int64?
    var downloadError: IPhoneTransferError?

    init(copyBytes: Int64? = nil, reportedBytes: Int64? = nil) {
        self.copyBytes = copyBytes
        self.reportedBytes = reportedBytes
    }

    var deleted: [String] { lock.withLock { _deleted } }
    var downloaded: [String] { lock.withLock { _downloaded } }

    func download(udid: String, file: IPhoneFileRef, to destination: URL) async throws -> Int64 {
        lock.withLock { _downloaded.append(file.path) }
        if let downloadError { throw downloadError }
        // A sparse file of the right length, so a 112 MB video costs nothing.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(copyBytes ?? file.bytes))
        return reportedBytes ?? file.bytes
    }

    func delete(udid: String, file: IPhoneFileRef) async throws {
        lock.withLock { _deleted.append(file.path) }
    }
}

@Suite struct IPhoneTests {
    static let udid = "00008030-000C08282610402E"
    static let mb: Int64 = 1_000_000

    static let diskUsage = """
    AmountDataAvailable: 1899155456
    AmountDataReserved: 209715200
    CalculateDiskUsage: OkilyDokily
    CameraUsage: 16729113438
    NANDInfo: AAECAwQFBgcICQoLDA0ODw==: more: colons
    PhotoUsage: 16729113438
    TotalDataCapacity: 57407352832
    TotalDiskCapacity: 64000000000
    TotalSystemCapacity: 6559047680
    """

    static func appsXML(_ apps: [(id: String, name: String, app: Int, data: Int)]) -> String {
        let dicts = apps.map { a in
            """
            <dict><key>CFBundleDisplayName</key><string>\(a.name)</string><key>CFBundleIdentifier</key><string>\(a.id)</string>\
            <key>DynamicDiskUsage</key><integer>\(a.data)</integer><key>StaticDiskUsage</key><integer>\(a.app)</integer></dict>
            """
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><array>\(dicts)</array></plist>"
    }

    static func line(_ size: Int64, _ date: String, _ name: String) -> String {
        "-rw-r--r--    1 mobile mobile \(size) \(date) \(name)"
    }

    static let prompt = "\u{1B}[0;30m\u{1B}[47mafc:\u{1B}[m\u{1B}[1;33m\u{1B}[44m/\u{1B}[m > "

    static let folders = prompt + """
    drwxr-xr-x    2 mobile mobile      14272 12 Sep 2026 14:44:12 110APPLE
    drwxr-xr-x    4 mobile mobile        128 01 Sep 2025 23:47:26 .MISC
    drwxr-xr-x    2 mobile mobile         64 06 Apr 2024 18:49:02 101APPLE
    """

    /// A phone with a 112 MB video, a 31 MB video, a 52 MB photo, a 3 MB photo and a 25 MB photo.
    func phone(name: String = "Sample iPhone", apps: [(id: String, name: String, app: Int, data: Int)] = [
        ("com.spotify.client", "Spotify", 280_000_000, 2_140_000_000), ("org.whispersystems.signal", "Signal", 150_000_000, 690_000_000),
    ]) -> FakeRunner {
        let u = Self.udid
        let lines: [String] = [
            Self.line(112 * Self.mb, "29 Sep 2025 10:11:12", "IMG_0908.MOV"),
            Self.line(31 * Self.mb, "01 Oct 2025 09:00:00", "IMG_0910.MOV"),
            Self.line(52 * Self.mb, "02 Oct 2025 09:00:00", "IMG_0911.DNG"),
            Self.line(3 * Self.mb, "03 Oct 2025 09:00:00", "IMG_0912.HEIC"),
            Self.line(25 * Self.mb, "04 Oct 2025 09:00:00", "IMG_0913.JPG"),
        ]
        var answers: [String: CommandResult] = [:]
        answers["idevice_id -l"] = FakeRunner.out(u + "\n")
        answers["ideviceinfo -u \(u) -k DeviceName"] = FakeRunner.out(name + "\n")
        answers["ideviceinfo -u \(u) -k ProductVersion"] = FakeRunner.out("18.6.2\n")
        answers["ideviceinfo -u \(u) -q com.apple.disk_usage.factory"] = FakeRunner.out(Self.diskUsage)
        answers[IPhoneProvider.listApps(u).joined(separator: " ")] = FakeRunner.out(Self.appsXML(apps))
        answers[IPhoneProvider.afc(["ls -l /DCIM"], u)] = FakeRunner.out(Self.folders)
        answers[IPhoneProvider.afc(["ls -l /DCIM/110APPLE"], u)] = FakeRunner.out(Self.prompt + lines.joined(separator: "\n"))
        answers[IPhoneProvider.afc(["ls -l /DCIM/101APPLE"], u)] = FakeRunner.out(Self.prompt)
        return FakeRunner(answers)
    }

    func scan(_ runner: FakeRunner, _ f: Fixture = Fixture()) async -> IPhoneSnapshot {
        await IPhoneProvider().snapshot(f.env(runner: runner))
    }

    // MARK: - Parsing

    @Test func diskUsageIgnoresNANDInfoAndReadsTheNumbers() throws {
        let values = diskUsageValues(Self.diskUsage)
        #expect(values["TotalDataCapacity"] == 57_407_352_832)
        #expect(values["AmountDataAvailable"] == 1_899_155_456)
        #expect(values["PhotoUsage"] == 16_729_113_438)
        #expect(values["NANDInfo"] == nil)
        let storage = try #require(IPhoneStorage(diskUsage: Self.diskUsage, apps: 5_000_000_000))
        #expect(storage.free == 1_899_155_456)
        #expect(storage.system == 6_559_047_680)
        #expect(IPhoneStorage(diskUsage: "CalculateDiskUsage: OkilyDokily", apps: 0) == nil)
    }

    @Test func installerPlistGivesNamesAndSizes() {
        let apps = parseApps(Self.appsXML([("com.a", "Alpha", 10, 20), ("com.b", "", 1, 2)]))
        #expect(apps == [IPhoneApp(bundleID: "com.a", name: "Alpha", appBytes: 10, dataBytes: 20),
                         IPhoneApp(bundleID: "com.b", name: "com.b", appBytes: 1, dataBytes: 2)])
        #expect(apps[0].bytes == 30)
        #expect(parseApps("not a plist").isEmpty)
    }

    @Test func afcListingStripsPromptEscapesAndSkipsFolders() throws {
        #expect(parseFolders(Self.folders) == ["101APPLE", "110APPLE"])
        let out = Self.prompt + Self.line(112 * Self.mb, "29 Sep 2025 10:11:12", "IMG_0908.MOV") + "\n"
            + "drwxr-xr-x    2 mobile mobile 64 06 Apr 2024 18:49:02 sub\n"
            + Self.line(5, "01 Jan 2026 00:00:01", "with space.JPG") + "\n"
        let files = parseListing(out, folder: "/DCIM/110APPLE")
        #expect(files.map(\.path) == ["/DCIM/110APPLE/IMG_0908.MOV", "/DCIM/110APPLE/with space.JPG"])
        #expect(files[0].bytes == 112_000_000)
        #expect(files[0].dateLabel == "29 Sep 2025")
        #expect(files[0].kind == .video)
        #expect(files[1].kind == .photo)
        #expect(stripANSI(Self.prompt) == "afc:/ > ")
    }

    @Test func phoneOnTheUSBBusIsFoundInSystemProfilerJSON() {
        let json = #"{"SPUSBDataType":[{"_name":"USB31Bus","_items":[{"_name":"Hub","_items":[{"_name":"iPhone","serial_num":"x"}]}]}]}"#
        #expect(usbHasIPhone(json))
        #expect(!usbHasIPhone(#"{"SPUSBDataType":[{"_name":"USB31Bus","_items":[{"_name":"Keyboard"}]}]}"#))
        #expect(!usbHasIPhone("garbage"))
    }

    @Test func deviceNamesBecomeSafeFolderNames() {
        #expect(folderName("Sam’s iPhone") == "Sam’s iPhone")
        #expect(folderName("a/b:c") == "a-b-c")
        #expect(folderName("..") == "iPhone")
    }

    // MARK: - Storage maths

    @Test func notVisibleIsWhatPhotosAppsAndSystemDontExplain() {
        let s = IPhoneStorage(dataCapacity: 60_000, dataAvailable: 10_000, system: 6_000, photos: 16_000, apps: 12_000)
        #expect(s.used == 50_000)
        #expect(s.notVisible == 16_000)
        #expect(s.parts.map(\.bytes).reduce(0, +) == 60_000)
        #expect(s.parts.map(\.part) == [.photos, .apps, .system, .notVisible, .free])
    }

    @Test func notVisibleNeverGoesNegative() {
        let s = IPhoneStorage(dataCapacity: 60_000, dataAvailable: 10_000, system: 6_000, photos: 30_000, apps: 30_000)
        #expect(s.notVisible == 0)
        let full = IPhoneStorage(dataCapacity: 100, dataAvailable: 500, system: 0, photos: 0, apps: 0)
        #expect(full.used == 0)
    }

    // MARK: - Items

    @Test func mediaListsBigFilesAndEveryLargeVideoBiggestFirst() async {
        let snap = await scan(phone())
        let media = snap.items.filter { $0.id.contains(".media.") }
        #expect(media.map(\.title) == ["IMG_0908.MOV", "IMG_0911.DNG", "IMG_0910.MOV"])
        #expect(media[0].id == "iphone.\(Self.udid).media./DCIM/110APPLE/IMG_0908.MOV")
        #expect(media[0].detail == "Video · 29 Sep 2025 · on iPhone")
        #expect(media[1].detail == "Photo · 2 Oct 2025 · on iPhone")
        #expect(media.allSatisfy { $0.risk == .yourData })
        #expect(snap.media.photoCount == 3 && snap.media.videoCount == 2)
        #expect(snap.media.videoBytes == 143 * Self.mb)
        #expect(snap.media.summary == "3 photos (80 MB, HEIC, JPG) · 2 videos (143 MB, MOV, MP4)")
    }

    @Test func mediaIsCappedAtTwoHundredBiggestFirst() {
        let files = (0..<250).map { IPhoneMediaFile(path: "/DCIM/100APPLE/V\($0).MOV", bytes: Int64(30 + $0) * Self.mb, date: Date()) }
        let items = IPhoneProvider().mediaItems(files, udid: Self.udid)
        #expect(items.count == 200)
        #expect(items.first?.title == "V249.MOV")
        #expect(items.last?.title == "V50.MOV")
    }

    @Test func appsAreListedWithAppAndDataSizes() async throws {
        let snap = await scan(phone())
        let apps = snap.items.filter { $0.id.contains(".app.") }
        #expect(apps.map(\.title) == ["Spotify", "Signal"])
        let spotify = try #require(apps.first)
        #expect(spotify.id == "iphone.\(Self.udid).app.com.spotify.client")
        #expect(spotify.bytes == 2_420_000_000)
        #expect(spotify.detail == "App \(formatBytes(280_000_000)) · Documents & Data \(formatBytes(2_140_000_000))")
        #expect(spotify.risk == .yourData)
        #expect(snap.storage?.apps == 3_260_000_000)
    }

    @Test func snapshotCarriesDeviceFacts() async {
        let snap = await scan(phone())
        #expect(snap.state == .ready)
        #expect(snap.name == "Sample iPhone")
        #expect(snap.subtitle == "iOS 18.6.2 · \(formatBytes(64_000_000_000))")
        #expect(snap.missingTools.isEmpty)
        #expect(await IPhoneProvider().isPresent(Fixture().env(runner: phone())))
    }

    // MARK: - States

    @Test func nothingConnectedMeansNoConcern() async {
        let runner = FakeRunner(["idevice_id -l": FakeRunner.out("\n")])
        #expect(await scan(runner).state == .notConnected)
        #expect(await IPhoneProvider().isPresent(Fixture().env(runner: runner)) == false)
    }

    @Test func missingLibimobiledeviceIsDetectedFromTheUSBBus() async {
        let usb = #"{"SPUSBDataType":[{"_name":"USB31Bus","_items":[{"_name":"iPhone"}]}]}"#
        let runner = FakeRunner(["system_profiler SPUSBDataType -json": FakeRunner.out(usb)])
        let snap = await scan(runner)
        #expect(snap.state == .toolsMissing)
        #expect(snap.state.message == "To see what's using your iPhone's storage, install libimobiledevice: brew install libimobiledevice ideviceinstaller")
        #expect(snap.items.isEmpty)
        #expect(await IPhoneProvider().isPresent(Fixture().env(runner: runner)))
        let none = FakeRunner(["system_profiler SPUSBDataType -json": FakeRunner.out(#"{"SPUSBDataType":[]}"#)])
        #expect(await scan(none).state == .notConnected)
    }

    @Test func lockedOrUntrustedPhoneAsksForTrust() async {
        let u = Self.udid
        for stderr in ["ERROR: Could not connect to lockdownd, error code -17", "ERROR: Device is not paired with this host",
                       "ERROR: Please enter the passcode on the device"] {
            let runner = FakeRunner(["idevice_id -l": FakeRunner.out(u), "ideviceinfo -u \(u) -k DeviceName": CommandResult(status: 255, stderr: stderr)])
            let snap = await scan(runner)
            #expect(snap.state == .locked)
            #expect(snap.state.message == "Unlock your iPhone and tap Trust")
            #expect(snap.items.isEmpty)
        }
        let odd = FakeRunner(["idevice_id -l": FakeRunner.out(u), "ideviceinfo -u \(u) -k DeviceName": CommandResult(status: 1, stderr: "boom")])
        #expect(await scan(odd).state == .failed("boom"))
    }

    @Test func missingInstallerOrAfcclientIsSaid() async {
        let runner = phone()
        runner.responses[IPhoneProvider.listApps(Self.udid).joined(separator: " ")] = nil
        runner.responses[IPhoneProvider.afc(["ls -l /DCIM"], Self.udid)] = nil
        let snap = await scan(runner)
        #expect(snap.missingTools == ["ideviceinstaller", "afcclient"])
        #expect(snap.state == .ready)
    }

    // MARK: - Plans

    @Test func uninstallingAnAppRunsTheInstallerAndWarnsAboutItsData() async throws {
        let f = Fixture()
        let env = f.env(runner: phone())
        let items = await IPhoneProvider().scan(env, pins: Pins())
        let spotify = try #require(items.first { $0.title == "Spotify" })
        let plan = await IPhoneProvider().plan([spotify.id], items: items, env: env)
        #expect(plan.steps.map(\.kind) == [.command(argv: ["ideviceinstaller", "-u", Self.udid, "uninstall", "com.spotify.client"])])
        #expect(plan.steps.first?.kind.undo == .never)
        #expect(plan.dangers == ["Uninstalling Spotify deletes everything it keeps on the iPhone. You can reinstall it from the App Store, but its data comes back only if the app syncs it somewhere."])
        // The provider already explained the data, so no second "is your data" line.
        #expect(dangerNotes(plan, items: items) == plan.dangers)
        #expect(caution(of: plan, items: items) == .dangerous)
    }

    @Test func movingMediaCopiesFirstAndWarnsAboutICloud() async throws {
        let f = Fixture()
        let env = f.env(runner: phone())
        let items = await IPhoneProvider().scan(env, pins: Pins())
        let video = try #require(items.first { $0.title == "IMG_0908.MOV" })
        let plan = await IPhoneProvider().plan([video.id], items: items, env: env)
        let folder = f.url("Pictures/From iPhone/Sample iPhone")
        #expect(plan.steps.map(\.kind) == [.moveFromIPhone(udid: Self.udid, files: [IPhoneFileRef(path: "/DCIM/110APPLE/IMG_0908.MOV", bytes: 112 * Self.mb)], to: folder)])
        #expect(plan.steps.first?.kind.undo.label == "Copied to your Mac first; deleted from the iPhone only once the copy is checked")
        #expect(plan.steps.first?.expectedBytes == 112 * Self.mb)
        #expect(plan.dangers == ["If iCloud Photos is on, deleting from this iPhone deletes from iCloud and your other devices too. The copies on this Mac stay."])
        // The copy stays on the Mac, so the generic "can't bring it back" note is not added.
        #expect(dangerNotes(plan, items: items) == plan.dangers)
    }

    @Test func chosenFolderReplacesTheDefault() async throws {
        let f = Fixture()
        let env = f.env(runner: phone())
        let provider = IPhoneProvider(destination: f.url("Backups"))
        let items = await provider.scan(env, pins: Pins())
        let plan = await provider.plan([items[0].id], items: items, env: env)
        #expect(plan.steps.first?.kind == .moveFromIPhone(udid: Self.udid, files: [IPhoneFileRef(path: items[0].id.replacingOccurrences(of: "iphone.\(Self.udid).media.", with: ""), bytes: items[0].bytes)],
                                                        to: f.url("Backups/Sample iPhone")))
    }

    // MARK: - Finding the file again

    @Test func aFileIsMatchedByNameAndExactSizeIgnoringFolders() {
        let candidates: [(name: String, bytes: Int64)] = [("IMG_0908.MOV", 277_003_663), ("IMG_0908.MOV", 5), ("IMG_0909.MOV", 277_003_663)]
        #expect(matchingFiles(name: "IMG_0908.MOV", bytes: 277_003_663, in: candidates) == [0])
        #expect(matchingFiles(name: "IMG_0908.MOV", bytes: 6, in: candidates).isEmpty)
        let twins: [(name: String, bytes: Int64)] = [("A.MOV", 9), ("A.MOV", 9)]
        #expect(matchingFiles(name: "A.MOV", bytes: 9, in: twins) == [0, 1])
    }

    @Test func serialsMatchThroughDroppedZerosAndDashes() {
        #expect(sameSerial("00008030-00C08282610402E", "00008030-000C08282610402E"))
        #expect(!sameSerial("00008030-000C08282610402F", "00008030-000C08282610402E"))
        #expect(!sameSerial("", ""))
    }

    // MARK: - Recheck

    @Test func recheckRefusesWhenThePhoneIsGoneOrTheItemIs() async throws {
        let f = Fixture()
        let runner = phone()
        let items = await IPhoneProvider().scan(f.env(runner: runner), pins: Pins())
        let video = try #require(items.first { $0.title == "IMG_0908.MOV" })
        let spotify = try #require(items.first { $0.title == "Spotify" })
        let ghost = Item(id: "iphone.\(Self.udid).app.com.removed", title: "Old", paths: [], bytes: 1, risk: .yourData)

        let still = await IPhoneProvider().recheck([video, spotify, ghost], env: f.env(runner: runner), pins: Pins())
        #expect(still.keys.sorted() == [ghost.id])
        #expect(still[ghost.id]?.reason == "Already gone")

        runner.responses["idevice_id -l"] = FakeRunner.out("\n")
        let gone = await IPhoneProvider().recheck([video, spotify], env: f.env(runner: runner), pins: Pins())
        #expect(gone.values.map(\.reason) == ["iPhone disconnected", "iPhone disconnected"])
    }

    @Test func recheckSaysWhenThePhoneLocked() async throws {
        let f = Fixture()
        let runner = phone()
        let items = await IPhoneProvider().scan(f.env(runner: runner), pins: Pins())
        runner.responses["ideviceinfo -u \(Self.udid) -k DeviceName"] = CommandResult(status: 255, stderr: "lockdownd error")
        let refusals = await IPhoneProvider().recheck(items, env: f.env(runner: runner), pins: Pins())
        #expect(Set(refusals.values.map(\.reason)) == ["Unlock your iPhone and tap Trust"])
    }

    // MARK: - Executor

    func execute(_ f: Fixture, files: [String], transfer: FakeTransfer?, runner: FakeRunner? = nil) async -> [StepResult] {
        let runner = runner ?? phone()
        let items = await IPhoneProvider().scan(f.env(runner: runner), pins: Pins())
        let ids = items.filter { i in files.contains { i.id.hasSuffix($0) } }.map(\.id)
        let provider = IPhoneProvider()
        let plan = await provider.plan(ids, items: items, env: f.env(runner: runner))
        return await Executor(env: f.env(runner: runner), logURL: f.url("state/actions.log"), iphone: transfer)
            .run(plan, provider: provider, items: items, pins: Pins()) { _ in }
    }

    @Test func moveCopiesChecksTheSizeThenDeletes() async throws {
        let f = Fixture()
        let transfer = FakeTransfer()
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: transfer)
        #expect(results.map(\.outcome) == [.done])
        #expect(transfer.deleted == ["/DCIM/110APPLE/IMG_0908.MOV"])
        let copy = f.url("Pictures/From iPhone/Sample iPhone/IMG_0908.MOV")
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int == 112_000_000)
    }

    @Test func moveNeverDeletesAFileWhoseCopyIsTheWrongSize() async {
        let f = Fixture()
        let transfer = FakeTransfer(copyBytes: 60)
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: transfer)
        #expect(transfer.downloaded == ["/DCIM/110APPLE/IMG_0908.MOV"])
        #expect(transfer.deleted.isEmpty)
        guard case .skipped(let why) = results.first?.outcome else { Issue.record("expected skipped"); return }
        #expect(why == "IMG_0908.MOV stays on the iPhone: the copy is 60 bytes, the iPhone says 112000000")
        // The bad copy is not left behind to be mistaken for the real one.
        #expect(!FileManager.default.fileExists(atPath: f.url("Pictures/From iPhone/Sample iPhone/IMG_0908.MOV").path))
    }

    @Test func moveNeverDeletesWhenThePhoneReportsNoSize() async {
        let f = Fixture()
        let transfer = FakeTransfer(copyBytes: 112_000_000, reportedBytes: 0)
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: transfer)
        #expect(transfer.deleted.isEmpty)
        guard case .skipped = results.first?.outcome else { Issue.record("expected skipped"); return }
    }

    @Test func moveDoesNotDeleteWhenTheDownloadFailsAndReportsWhy() async {
        let f = Fixture()
        let transfer = FakeTransfer()
        transfer.downloadError = IPhoneTransferError("macOS didn't let Ballast open the iPhone's photos.", denied: true)
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: transfer)
        #expect(transfer.deleted.isEmpty)
        #expect(results.map(\.outcome) == [.failed("IMG_0908.MOV: macOS didn't let Ballast open the iPhone's photos.")])
    }

    @Test func moveKeepsAnExistingFileByNamingTheCopyApart() async throws {
        let f = Fixture()
        f.file("Pictures/From iPhone/Sample iPhone/IMG_0908.MOV", bytes: 7)
        let transfer = FakeTransfer()
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: transfer)
        #expect(results.map(\.outcome) == [.done])
        #expect(try FileManager.default.attributesOfItem(atPath: f.url("Pictures/From iPhone/Sample iPhone/IMG_0908.MOV").path)[.size] as? Int == 7)
        #expect(FileManager.default.fileExists(atPath: f.url("Pictures/From iPhone/Sample iPhone/IMG_0908 2.MOV").path))
    }

    @Test func moveWithoutAnImageCaptureBridgeFailsWithoutTouchingAnything() async {
        let f = Fixture()
        let results = await execute(f, files: ["IMG_0908.MOV"], transfer: nil)
        guard case .failed = results.first?.outcome else { Issue.record("expected failed"); return }
    }

    @Test func executorSkipsAMoveWhenThePhoneWasUnplugged() async {
        let f = Fixture()
        let runner = phone()
        let transfer = FakeTransfer()
        let items = await IPhoneProvider().scan(f.env(runner: runner), pins: Pins())
        let plan = await IPhoneProvider().plan([items.first { $0.title == "IMG_0908.MOV" }!.id], items: items, env: f.env(runner: runner))
        runner.responses["idevice_id -l"] = FakeRunner.out("")
        let results = await Executor(env: f.env(runner: runner), logURL: f.url("state/actions.log"), iphone: transfer)
            .run(plan, provider: IPhoneProvider(), items: items, pins: Pins()) { _ in }
        #expect(results.map(\.outcome) == [.skipped("iPhone disconnected")])
        #expect(transfer.downloaded.isEmpty)
    }

    @Test func uninstallRunsThroughTheInstaller() async {
        let f = Fixture()
        let runner = phone()
        runner.responses["ideviceinstaller -u \(Self.udid) uninstall com.spotify.client"] = FakeRunner.ok
        let results = await execute(f, files: ["com.spotify.client"], transfer: nil, runner: runner)
        #expect(results.map(\.outcome) == [.done])
        #expect(runner.calls.contains("ideviceinstaller -u \(Self.udid) uninstall com.spotify.client"))
    }

    // MARK: - A real phone

    /// Opt-in: `BALLAST_REAL_IPHONE=1 make test`. Reads only; nothing is moved, deleted or uninstalled.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BALLAST_REAL_IPHONE"] == "1"))
    func realPhoneSummary() async {
        let snap = await IPhoneProvider().snapshot(Environment.live(projectRoots: []))
        var out = ["state: \(snap.state)", "device: \(snap.name) · \(snap.subtitle)", "udid: \(snap.udid ?? "-")",
                   "missing tools: \(snap.missingTools)"]
        if let s = snap.storage {
            out += ["data capacity \(s.dataCapacity) · free \(s.free) · used \(s.used)", "photos \(s.photos) · apps \(s.apps) · system \(s.system) · not visible \(s.notVisible)"]
        }
        out.append("camera roll: \(snap.media.summary)")
        let apps = snap.items.filter { $0.id.contains(".app.") }
        out.append("\(apps.count) apps, \(snap.items.count - apps.count) media items")
        out += snap.items.prefix(8).map { "  \($0.title) · \(formatBytes($0.bytes)) · \($0.detail ?? "")" }
        out += apps.prefix(5).map { "  app \($0.title) · \(formatBytes($0.bytes)) · \($0.detail ?? "")" }
        print("---- real iPhone ----\n" + out.joined(separator: "\n") + "\n---------------------")
        #expect(snap.state == .ready)
    }
}
