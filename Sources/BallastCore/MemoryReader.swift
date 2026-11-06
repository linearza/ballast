import Darwin
import Foundation

public protocol MemoryReading: Sendable {
    func system() -> SystemMemory?
    func processes() -> [ProcessSample]
}

/// Reads memory straight from the kernel. Never launches a process.
public struct LiveMemoryReader: MemoryReading {
    public init() {}

    public func system() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Int64(getpagesize())
        // Matches Activity Monitor's "Memory Used".
        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Int64(swap.xsu_used) : 0
        return SystemMemory(physical: Int64(ProcessInfo.processInfo.physicalMemory), used: max(0, pages * page), swapUsed: swapUsed)
    }

    public func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: capacity + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard bytes > 0 else { return [] }
        let n = min(Int(bytes), pids.count)  // proc_listallpids returns a pid count, not bytes
        return pids.prefix(n).filter { $0 > 0 }.compactMap { Self.sample(pid: $0) }
    }

    /// One process, or nil when any of the required calls fail (it exited, or isn't ours to read).
    static func sample(pid: Int32) -> ProcessSample? {
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path: String? = pathLen > 0 ? String(cString: pathBuf) : nil

        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }

        var args: [String] = []
        var cwd: String?
        if let path, runtimeNames.contains(path.split(separator: "/").last.map(String.init) ?? "") {
            args = processArguments(pid: pid)
            cwd = workingDirectory(pid: pid)
        }
        return ProcessSample(pid: pid, startSeconds: info.pbi_start_tvsec, uid: info.pbi_uid, path: path,
                             args: args, cwd: cwd, footprint: Int64(clamping: usage.ri_phys_footprint))
    }

    private static func workingDirectory(pid: Int32) -> String? {
        var vp = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, size) == size else { return nil }
        let s = withUnsafePointer(to: &vp.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return s.isEmpty ? nil : s
    }

    /// argv from KERN_PROCARGS2: argc, the executable path, padding NULs, then argc strings.
    private static func processArguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // skip exec path
        while i < size, buf[i] == 0 { i += 1 }   // skip padding
        var out: [String] = []
        while out.count < argc, i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }
}
