import Foundation

public struct Measured: Sendable, Equatable {
    public var bytes: Int64
    /// Part of it couldn't be read, so `bytes` is a lower bound.
    public var partial: Bool

    public init(bytes: Int64 = 0, partial: Bool = false) {
        self.bytes = bytes
        self.partial = partial
    }
}

private struct FileKey: Hashable { var dev: Int32; var ino: UInt64 }

private struct Tally {
    var bytes: Int64 = 0
    var partial = false
    /// Files with more than one hard link, counted once when tallies are merged.
    var linked: [FileKey: Int64] = [:]

    mutating func add(_ st: stat) {
        let size = Int64(st.st_blocks) * 512
        if (st.st_mode & S_IFMT) != S_IFDIR && st.st_nlink > 1 {
            linked[FileKey(dev: st.st_dev, ino: st.st_ino)] = size
        } else {
            bytes += size
        }
    }

    mutating func merge(_ other: Tally) {
        bytes += other.bytes
        partial = partial || other.partial
        linked.merge(other.linked) { a, _ in a }
    }

    var result: Measured { Measured(bytes: bytes + linked.values.reduce(0, +), partial: partial) }
}

/// Allocated size on disk of the given files and folders. Symlinks are never
/// followed, other volumes aren't entered, and hard links count once.
public func measure(_ urls: [URL]) async -> Measured {
    await Task(priority: .utility) { await measureNow(urls) }.value
}

private func measureNow(_ urls: [URL]) async -> Measured {
    var top = Tally()
    var roots: [String] = []
    for url in urls {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno != ENOENT { top.partial = true }
            continue
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            continue
        case S_IFDIR:
            top.add(st)
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                top.partial = true
                continue
            }
            for name in children {
                let child = url.appending(path: name).path
                var cst = stat()
                guard lstat(child, &cst) == 0 else { top.partial = true; continue }
                guard cst.st_dev == st.st_dev else { continue }
                if (cst.st_mode & S_IFMT) == S_IFDIR { roots.append(child) } else if (cst.st_mode & S_IFMT) != S_IFLNK { top.add(cst) }
            }
        default:
            top.add(st)
        }
    }

    // Walk the top-level folders four at a time.
    var total = top
    await withTaskGroup(of: Tally.self) { group in
        var next = roots.makeIterator()
        for _ in 0..<4 { if let r = next.next() { group.addTask { walk(r) } } }
        for await t in group {
            total.merge(t)
            if let r = next.next() { group.addTask { walk(r) } }
        }
    }
    return total.result
}

private func walk(_ path: String) -> Tally {
    var tally = Tally()
    let cPath = strdup(path)
    defer { free(cPath) }
    var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
        tally.partial = true
        return tally
    }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
        let e = entry.pointee
        switch Int32(e.fts_info) {
        case FTS_D, FTS_F, FTS_DEFAULT:
            if let st = e.fts_statp { tally.add(st.pointee) }
        case FTS_DNR, FTS_ERR, FTS_NS:
            tally.partial = true
            if Int32(e.fts_info) == FTS_DNR, let st = e.fts_statp { tally.add(st.pointee) }
        default:
            break // FTS_DP (post-order), FTS_SL, FTS_SLNONE, FTS_DC (cycle)
        }
    }
    return tally
}
