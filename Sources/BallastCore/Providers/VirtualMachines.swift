import Foundation

/// Container runtimes other than Docker Desktop (Colima, Lima, minikube, Podman, OrbStack,
/// Rancher Desktop) and virtual machines from UTM, Parallels and VMware Fusion.
public struct VirtualMachinesProvider: Provider {
    public init() {}
    public let id = "vms"
    public let title = "Other runtimes and VMs"
    public let section = Section.containers
    public let symbol = "server.rack"

    static let podman = ".local/share/containers/podman/machine"
    static let orbstack = "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
    static let rancher = "Library/Application Support/rancher-desktop/lima"
    static let utm = "Library/Containers/com.utmapp.UTM/Data/Documents"
    static let parallels = "Parallels"
    static let vmware = "Virtual Machines.localized"
    /// The app each kind of item belongs to, so its items are left alone while it's open.
    static let apps = ["orbstack": "dev.kdrag0n.MacVirt", "rancher": "io.rancherdesktop.app",
                       "parallels": "com.parallels.desktop.console", "vmware": "com.vmware.fusion"]

    public func isPresent(_ env: Environment) async -> Bool {
        [".colima", ".lima", ".minikube", Self.podman, Self.orbstack, Self.rancher, Self.utm, Self.parallels, Self.vmware]
            .contains { exists(env.path($0)) }
    }

    /// Lima and Colima keep internal folders whose names start with `_`.
    func instances(_ dir: URL) -> [String] { subfolders(dir).filter { !$0.hasPrefix("_") } }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        func badges(_ running: Bool) -> Set<Badge> { running ? [.running] : [] }

        // Colima runs each profile as a Lima VM named colima (default) or colima-<profile>.
        for profile in instances(env.path(".colima")) {
            let vm = env.path(".colima/_lima/\(profile == "default" ? "colima" : "colima-\(profile)")")
            items.append(Item(id: "vm.colima.\(profile)", title: "Colima \(profile)", detail: "Colima VM with its images and containers",
                              paths: [env.path(".colima/\(profile)")] + (exists(vm) ? [vm] : []), bytes: 0, risk: .review,
                              badges: badges(hasLivePidFile(vm))))
        }
        for vm in instances(env.path(".lima")) {
            let dir = env.path(".lima/\(vm)")
            items.append(Item(id: "vm.lima.\(vm)", title: "Lima \(vm)", detail: "Lima VM", paths: [dir], bytes: 0, risk: .review,
                              badges: badges(hasLivePidFile(dir))))
        }
        for profile in subfolders(env.path(".minikube/machines")) {
            let paths = [env.path(".minikube/machines/\(profile)"), env.path(".minikube/profiles/\(profile)")].filter(exists)
            items.append(Item(id: "vm.minikube.\(profile)", title: "minikube \(profile)", detail: "minikube cluster",
                              paths: paths, bytes: 0, risk: .review))
        }
        if exists(env.path(Self.podman)) {
            items.append(Item(id: "vm.podman", title: "Podman machines", detail: "Podman's Linux VMs with their images and containers",
                              paths: [env.path(Self.podman)], bytes: 0, risk: .review))
        }
        if exists(env.path(Self.rancher)) {
            items.append(Item(id: "vm.rancher", title: "Rancher Desktop VM", detail: "Its images, containers and Kubernetes",
                              paths: [env.path(Self.rancher)], bytes: 0, risk: .review,
                              badges: badges(isAppRunning(bundleID: Self.apps["rancher"]!))))
        }
        for name in subfolders(env.path(Self.parallels)) where name.hasSuffix(".pvm") {
            items.append(Item(id: "vm.parallels.\(name)", title: String(name.dropLast(4)), detail: "Parallels virtual machine",
                              paths: [env.path("\(Self.parallels)/\(name)")], bytes: 0, risk: .yourData,
                              badges: badges(isAppRunning(bundleID: Self.apps["parallels"]!))))
        }
        for name in subfolders(env.path(Self.vmware)) where name.hasSuffix(".vmwarevm") {
            items.append(Item(id: "vm.vmware.\(name)", title: String(name.dropLast(9)), detail: "VMware Fusion virtual machine",
                              paths: [env.path("\(Self.vmware)/\(name)")], bytes: 0, risk: .yourData,
                              badges: badges(isAppRunning(bundleID: Self.apps["vmware"]!))))
        }
        var all = await measured(items)
        // OrbStack and UTM keep their data in folders macOS protects: measured only when you ask.
        if exists(env.path(Self.orbstack)) {
            var item = lockedItem(id: "vm.orbstack", title: "OrbStack data", detail: "Its Linux machines, images and containers",
                                  paths: [env.path(Self.orbstack)], risk: .review)
            if isAppRunning(bundleID: Self.apps["orbstack"]!) { item.badges.insert(.running) }
            all.append(item)
        }
        if exists(env.path(Self.utm)) {
            all.append(lockedItem(id: "vm.utm", title: "UTM virtual machines", detail: "Delete them one at a time in UTM",
                                  paths: [env.path(Self.utm)], risk: .yourData))
        }
        return all
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for item in items where ids.contains(item.id) {
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let kind = parts[1], name = parts.count > 2 ? parts[2] : ""
            if item.badges.contains(.running) {
                let stop = switch kind {
                case "colima": "Stop it first with colima stop --profile \(name)"
                case "lima": "Stop it first with limactl stop \(name)"
                default: "Quit the app first"
                }
                plan.refusals.append(Refusal(itemID: item.id, reason: "Running. \(stop)"))
                continue
            }
            if kind == "utm" {
                plan.refusals.append(Refusal(itemID: item.id, reason: "Each VM is your data. Delete the ones you don't need in UTM"))
                continue
            }
            let tool: [String]? = switch kind {
            case "colima": ["colima", "delete", "--force", "--profile", name]
            case "lima": ["limactl", "delete", "--force", name]
            case "minikube": ["minikube", "delete", "--profile", name]
            case "podman": ["podman", "machine", "reset", "--force"]
            default: nil
            }
            let step: StepKind = if let tool, await env.runner.which(tool[0]) != nil { .command(argv: tool) } else { .trash(item.paths) }
            if item.risk == .yourData { plan.warnings.append("\(item.title) is a whole virtual machine, with everything saved inside it.") }
            plan.steps.append(Step("Remove \(item.title)", step, bytes: item.bytes, itemID: item.id))
        }
        return plan
    }
}
