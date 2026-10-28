import Foundation

/// Android SDK system images and NDKs, and the emulators made from them.
public struct AndroidProvider: Provider {
    public init() {}
    public let id = "android"
    public let title = "Android"
    public let section = Section.toolchains
    public let symbol = "iphone.gen1"

    static let sdk = "Library/Android/sdk"

    public func isPresent(_ env: Environment) async -> Bool {
        exists(env.path(Self.sdk)) || exists(env.path(".android/avd"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        // system-images/<api>/<tag>/<abi>, named by sdkmanager as system-images;<api>;<tag>;<abi>.
        let images = env.path("\(Self.sdk)/system-images")
        for api in subfolders(images) {
            for tag in subfolders(images.appending(path: api)) {
                for abi in subfolders(images.appending(path: "\(api)/\(tag)")) {
                    items.append(Item(id: "android.image.\(api);\(tag);\(abi)", title: "\(api) \(tag) image",
                                      detail: "System image · \(abi)", paths: [images.appending(path: "\(api)/\(tag)/\(abi)")],
                                      bytes: 0, risk: .regenerable))
                }
            }
        }
        for v in subfolders(env.path("\(Self.sdk)/ndk")) {
            items.append(Item(id: "android.ndk.\(v)", title: "NDK \(v)", detail: "Android NDK",
                              paths: [env.path("\(Self.sdk)/ndk/\(v)")], bytes: 0, risk: .regenerable))
        }
        let avd = env.path(".android/avd")
        for name in subfolders(avd) where name.hasSuffix(".avd") {
            let base = String(name.dropLast(4))
            let ini = avd.appending(path: "\(base).ini")
            items.append(Item(id: "android.avd.\(base)", title: "\(base.replacingOccurrences(of: "_", with: " ")) emulator",
                              detail: "Android Virtual Device with its saved state",
                              paths: [avd.appending(path: name)] + (exists(ini) ? [ini] : []), bytes: 0, risk: .review,
                              badges: hasLivePidFile(avd.appending(path: name)) || exists(avd.appending(path: "\(name)/hardware-qemu.ini.lock"))
                                  ? [.running] : []))
        }
        return await measured(items)
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let sdkmanager = await env.runner.which("sdkmanager") != nil
        let avdmanager = await env.runner.which("avdmanager") != nil
        let running = items.filter { ids.contains($0.id) && $0.badges.contains(.running) }
        var plan = planEach(ids.filter { id in !running.contains { $0.id == id } }, items: items, noun: "emulator") { item in
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let kind: StepKind = switch parts[1] {
            case "image" where sdkmanager: .command(argv: ["sdkmanager", "--uninstall", "system-images;\(parts[2])"])
            case "ndk" where sdkmanager: .command(argv: ["sdkmanager", "--uninstall", "ndk;\(parts[2])"])
            case "avd" where avdmanager: .command(argv: ["avdmanager", "delete", "avd", "-n", parts[2]])
            default: .trash(item.paths)
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
        plan.refusals += running.map { Refusal(itemID: $0.id, reason: "Running. Close the emulator first") }
        return plan
    }
}
