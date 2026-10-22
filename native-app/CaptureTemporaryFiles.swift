import Foundation
import Darwin

struct CaptureCleanupReport {
    var removed = 0
    var failed = 0
    var message: String? {
        guard removed > 0 || failed > 0 else { return nil }
        return "已清理 \(removed) 份异常退出的临时抓包记录。" +
            (failed > 0 ? "另有 \(failed) 份暂未清理，将在下次启动或抓包前重试。" : "")
    }
}

enum CaptureTemporaryFiles {
    static let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    static let prefix = "MacPulseCapture-"
    static let leaseName = "lease"
    static let leaseData = Data("MacPulse capture lease v1\n".utf8)
    static let legacyAge: TimeInterval = 24 * 60 * 60
    private static let allowed = Set(["active", "capture.pcap", leaseName])

    static func createLease(in directory: URL) throws -> Int32 {
        let fd = open(directory.appendingPathComponent(leaseName).path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DiskError.message("无法创建抓包记录锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0,
              leaseData.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == leaseData.count else {
            Darwin.close(fd); throw DiskError.message("无法锁定抓包记录。")
        }
        return fd
    }

    private static func names(in fd: Int32) -> [String]? {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); return nil }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? result : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            // Capture sessions contain at most three files; never traverse a foreign tree.
            if result.count > allowed.count { return nil }
        }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func regular(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_uid == geteuid() && info.st_nlink == 1
    }
    private static func modified(_ info: stat) -> TimeInterval {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    // Directory-relative, nonrecursive removal never follows links or opens exported files elsewhere.
    // Holding the session lease protects both an in-flight capture and retained UI results.
    static func cleanup(root: URL = root, now: Date = Date()) -> CaptureCleanupReport {
        var report = CaptureCleanupReport()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { report.failed = 1; return report }
        defer { Darwin.close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else { report.failed = 1; return report }
        let copy = dup(rootFD)
        guard copy >= 0 else { report.failed = 1; return report }
        guard let entries = fdopendir(copy) else { Darwin.close(copy); report.failed = 1; return report }
        defer { closedir(entries) }
        var considered = 0
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            considered += 1
            if considered > 5_000 { break }
            switch clean(name, in: rootFD, device: rootInfo.st_dev, now: now.timeIntervalSince1970) {
            case 1: report.removed += 1
            case -1: report.failed += 1
            default: break
            }
        }
        return report
    }

    private static func clean(_ name: String, in root: Int32, device: dev_t, now: TimeInterval) -> Int {
        let dir = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return 0 }
        defer { Darwin.close(dir) }
        var original = stat()
        guard fstat(dir, &original) == 0, original.st_uid == geteuid(), original.st_dev == device,
              original.st_mode & 0o777 == 0o700, let files = names(in: dir), Set(files).isSubset(of: allowed) else { return 0 }
        var identities: [String: stat] = [:]
        for file in files {
            var info = stat()
            guard fstatat(dir, file, &info, AT_SYMLINK_NOFOLLOW) == 0, regular(info) else { return 0 }
            identities[file] = info
        }
        let lease: Int32
        if let info = identities[leaseName] {
            lease = openat(dir, leaseName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lease >= 0 else { return -1 }
            defer { Darwin.close(lease) }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { return 0 }
            var actual = stat(), bytes = [UInt8](repeating: 0, count: leaseData.count)
            guard fstat(lease, &actual) == 0, same(info, actual), regular(actual), actual.st_size == off_t(leaseData.count),
                  bytes.withUnsafeMutableBytes({ Darwin.read(lease, $0.baseAddress, $0.count) }) == bytes.count,
                  Data(bytes) == leaseData else { return 0 }
            // The lock must stay held through unlink/rmdir, including against a second app instance.
            return remove(files, identities: identities, directory: dir, name: name, root: root, original: original)
        } else {
            // Old versions had no lease. Leave fresh/possibly active records alone for at least a day.
            let newest = identities.values.map(modified).reduce(modified(original), max)
            guard now - newest >= legacyAge else { return 0 }
            return remove(files, identities: identities, directory: dir, name: name, root: root, original: original)
        }
    }
    private static func remove(_ files: [String], identities: [String: stat], directory: Int32,
                               name: String, root: Int32, original: stat) -> Int {
        var current = stat()
        guard fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(original, current),
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), let remaining = names(in: directory), Set(remaining) == Set(files) else { return 0 }
        // Removing 'active' first also prevents a late authorization from starting an orphan capture.
        for file in ["active", "capture.pcap", leaseName] where files.contains(file) {
            guard let expected = identities[file], fstatat(directory, file, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  same(expected, current), regular(current) else { return -1 }
            guard unlinkat(directory, file, 0) == 0 else { return -1 }
        }
        return unlinkat(root, name, AT_REMOVEDIR) == 0 ? 1 : -1
    }
}
