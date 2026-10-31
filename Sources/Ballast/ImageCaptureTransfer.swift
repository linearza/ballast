import BallastCore
import Foundation
@preconcurrency import ImageCaptureCore

/// Copies files off an iPhone and deletes them with ImageCaptureCore, the framework behind Image Capture.
/// It goes through the Photos stack on the phone, so the library stays consistent; deleting over AFC would not.
/// The camera session opens on first use and closes a little after the last.
final class ImageCaptureTransfer: NSObject, IPhoneMediaTransfer, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, @unchecked Sendable {
    /// Wraps an Image Capture object so it can cross into the closures that run on the main thread.
    private struct Box<T>: @unchecked Sendable { let value: T }

    private let lock = NSLock()
    private var browser: ICDeviceBrowser?
    private var cameras: [ICCameraDevice] = []
    private var ready: Set<ObjectIdentifier> = []
    private var failures: [ObjectIdentifier: NSError] = [:]
    private var lastUse = Date()

    static let idleSeconds = 20.0
    static let notFound = "Ballast can't see the iPhone through Image Capture. Unlock it, tap Trust, and try again."
    static let deniedMessage = "macOS didn't let Ballast open the iPhone's photos. Allow Ballast in System Settings → Privacy & Security, then try again."

    // MARK: - IPhoneMediaTransfer

    func download(udid: String, path: String, to destination: URL) async throws -> Int64 {
        let (_, file) = try await locate(udid: udid, path: path)
        let wanted = destination.lastPathComponent
        let saved: String = try await withCheckedThrowingContinuation { cont in
            let file = Box(value: file)
            DispatchQueue.main.async {
                _ = file.value.requestDownload(options: [.downloadsDirectoryURL: destination.deletingLastPathComponent(),
                                                         .saveAsFilename: wanted, .overwrite: false]) { name, error in
                    if let error { cont.resume(throwing: self.describe(error)) } else { cont.resume(returning: name ?? "") }
                }
            }
        }
        guard saved == wanted else {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent().appending(path: saved))
            throw IPhoneTransferError("Image Capture saved the copy under another name")
        }
        touch()
        return Int64(file.fileSize)
    }

    func delete(udid: String, path: String) async throws {
        let (camera, file) = try await locate(udid: udid, path: path)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let camera = Box(value: camera), file = Box(value: file)
            DispatchQueue.main.async {
                _ = camera.value.requestDeleteFiles([file.value], deleteFailed: { _ in }) { _, error in
                    if let error { cont.resume(throwing: self.describe(error)) } else { cont.resume() }
                }
            }
        }
        touch()
    }

    // MARK: - Finding the file

    /// The camera and the one file on it at `/DCIM/<folder>/<name>`. Two matches mean Ballast can't tell which, so neither is touched.
    private func locate(udid: String, path: String) async throws -> (ICCameraDevice, ICCameraFile) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "DCIM" else { throw IPhoneTransferError("Not a camera roll file: \(path)") }
        let camera = try await openCamera(udid: udid)
        let matches = await MainActor.run {
            Box(value: (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
                $0.name == parts[2] && ($0.parentFolder?.name).map { $0 == parts[1] } ?? true
            })
        }.value
        guard let file = matches.first else { throw IPhoneTransferError("Already gone") }
        guard matches.count == 1 else { throw IPhoneTransferError("\(parts[2]) matches more than one file on the iPhone") }
        return (camera, file)
    }

    // MARK: - Opening the camera

    private func openCamera(udid: String) async throws -> ICCameraDevice {
        touch()
        await MainActor.run { start() }
        let key = udid.replacingOccurrences(of: "-", with: "").uppercased()
        var found: ICCameraDevice?
        for _ in 0..<80 where found == nil {
            found = lock.withLock { cameras.first { ($0.serialNumberString ?? "").replacingOccurrences(of: "-", with: "").uppercased() == key }
                ?? (cameras.count == 1 ? cameras[0] : nil) }
            if found == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let camera = found else { throw IPhoneTransferError(Self.notFound) }
        let id = ObjectIdentifier(camera)
        if !lock.withLock({ ready.contains(id) }) {
            let box = Box(value: camera)
            await MainActor.run { box.value.delegate = self; box.value.requestOpenSession() }
            // Image Capture reads the whole catalogue before it says the camera is ready.
            for _ in 0..<480 {
                if let error = lock.withLock({ failures[id] }) { throw describe(error) }
                if lock.withLock({ ready.contains(id) }) { return camera }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw IPhoneTransferError("The iPhone took too long to share its photos. Unlock it and try again.")
        }
        return camera
    }

    @MainActor private func start() {
        guard browser == nil else { return }
        let b = ICDeviceBrowser()
        b.delegate = self
        b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        b.start()
        browser = b
    }

    private func touch() {
        lock.withLock { lastUse = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds + 1) { [self] in
            guard Date().timeIntervalSince(lock.withLock { lastUse }) >= Self.idleSeconds else { return }
            let open = lock.withLock { () -> [ICCameraDevice] in defer { ready = []; cameras = [] }; return cameras }
            for camera in open { camera.requestCloseSession() }
            browser?.stop()
            browser = nil
        }
    }

    private func describe(_ error: Error) -> IPhoneTransferError {
        let ns = error as NSError
        let denied = ns.domain == ICErrorDomain && [-21343, -21249].contains(ns.code)
        return IPhoneTransferError(denied ? Self.deniedMessage : ns.localizedDescription, denied: denied)
    }

    // MARK: - Delegates (called by Image Capture, usually on the main thread)

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        lock.withLock { if !cameras.contains(camera) { cameras.append(camera) } }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lock.withLock { cameras.removeAll { $0 === device }; ready.remove(ObjectIdentifier(device)) }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { lock.withLock { failures[ObjectIdentifier(device)] = error as NSError } }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        lock.withLock { ready.insert(ObjectIdentifier(device)); failures[ObjectIdentifier(device)] = nil }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        lock.withLock { _ = ready.remove(ObjectIdentifier(device)) }
    }

    func didRemove(_ device: ICDevice) {
        lock.withLock { cameras.removeAll { $0 === device }; ready.remove(ObjectIdentifier(device)) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        lock.withLock { failures[ObjectIdentifier(device)] = NSError(domain: ICErrorDomain, code: -21343) }
    }
}
