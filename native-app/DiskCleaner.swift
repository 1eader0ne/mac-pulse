import Foundation
import Darwin

enum DiskKind: Int, CaseIterable {
    case caches, logs, large
    var title: String { ["旧缓存", "旧日志", "大文件"][rawValue] }
    var age: TimeInterval { self == .caches ? 7 * 86400 : self == .logs ? 30 * 86400 : 0 }
    var explanation: String {
        switch self {
        case .caches: return "仅检查 7 天未修改的用户缓存；先退出相关应用，缓存可能重新生成。"
        case .logs: return "仅检查 30 天未修改的用户日志；保留排查问题时仍需要的日志。"
        case .large: return "检查至少 100 MiB 的普通文件。大文件不等于垃圾，请逐项确认用途。"
        }
    }
}
func diskContains(_ path: String, in root: String) -> Bool {
    root == "/" ? path.hasPrefix("/") && path != "/" : path.hasPrefix(root + "/")
}
func diskStat(_ url: URL) throws -> stat {
    var s = stat()
    guard lstat(url.path, &s) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return s
}
func diskIsRegular(_ s: stat) -> Bool { (s.st_mode & S_IFMT) == S_IFREG }
func diskSame(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}
struct DiskScope {
    let root: URL
    let kind: DiskKind
    let home: URL
    let isWholeDisk: Bool
    private init(wholeDiskRoot: URL, home: URL) {
        root = wholeDiskRoot; kind = .large; self.home = home; isWholeDisk = true
    }
    static func wholeDisk(root: URL = URL(fileURLWithPath: "/", isDirectory: true),
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> DiskScope {
        let r = root.standardizedFileURL
        guard r.path == r.resolvingSymlinksInPath().path else { throw DiskError.message("全盘扫描入口不能是链接。") }
        return DiskScope(wholeDiskRoot: r, home: home.resolvingSymlinksInPath().standardizedFileURL)
    }
    // A broad read scope never grants broad cleanup rights. Keep personal-folder validation below.
    func permitsPersonalCleanup(_ url: URL) -> Bool {
        guard diskContains(url.path, in: home.path), diskContains(url.path, in: root.path) else { return false }
        let relative = url.path.dropFirst(home.path.count + 1).split(separator: "/").map(String.init)
        guard relative.count > 1, relative.first != "Library", !relative.contains(where: { $0.hasPrefix(".") ||
            Self.packageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) else { return false }
        return true
    }
    static let packageExtensions = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "sparsebundle", "pkg", "rtfd", "xcodeproj", "playground"]
    init(root: URL, kind: DiskKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let h = home.resolvingSymlinksInPath().standardizedFileURL
        let r = root.standardizedFileURL
        // An explicitly selected personal folder is allowed; Library is limited to these two roots.
        guard r.path == r.resolvingSymlinksInPath().path, diskContains(r.path, in: h.path),
              !r.pathComponents.contains(where: { $0.hasPrefix(".") }), !Self.isPackage(r) else {
            throw DiskError.message("请选择当前用户下的普通个人文件夹；不扫描链接、隐藏目录或应用包。")
        }
        let cache = h.appendingPathComponent("Library/Caches").path
        let logs = h.appendingPathComponent("Library/Logs").path
        let library = h.appendingPathComponent("Library").path
        let allowed = kind == .caches ? r.path == cache : kind == .logs ? r.path == logs :
            !(r.path == library || diskContains(r.path, in: library))
        guard allowed else { throw DiskError.message("此范围受到保护。缓存和日志请使用对应的专用扫描。") }
        self.root = r; self.kind = kind; self.home = h; isWholeDisk = false
    }
    static func isPackage(_ url: URL) -> Bool {
        return packageExtensions.contains(url.pathExtension.lowercased()) || ((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true)
    }
    func validatePath(_ url: URL) throws {
        if isWholeDisk {
            guard permitsPersonalCleanup(url) else { throw DiskError.message("此文件受保护，仅可查看；全盘扫描不会扩大清理范围。") }
            let personal = try DiskScope(root: url.deletingLastPathComponent(), kind: .large, home: home)
            try personal.validatePath(url); return
        }
        let u = url.standardizedFileURL
        guard diskContains(u.path, in: root.path), u.path == url.path else { throw DiskError.message("文件超出扫描范围。") }
        // Recheck all ancestors, including root, to reject replacement with a symlink/package.
        var cursor = u.deletingLastPathComponent()
        while cursor.path != home.path && cursor.path != "/" {
            let s = try diskStat(cursor)
            guard (s.st_mode & S_IFMT) == S_IFDIR, !Self.isPackage(cursor), !cursor.lastPathComponent.hasPrefix(".") else {
                throw DiskError.message("目录已变更、属于文件包或是链接，已跳过。")
            }
            cursor.deleteLastPathComponent()
        }
        guard cursor.path == home.path else { throw DiskError.message("文件超出个人目录。") }
    }
}
enum DiskError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(t) = self { return t }; return nil }
}
struct DiskCandidate {
    let url: URL
    let scope: DiskScope
    let identity: stat
    var protectedByContainer = false
    var logical: UInt64 { UInt64(max(0, identity.st_size)) }
    var allocated: UInt64 { UInt64(max(0, identity.st_blocks)) * 512 }
    var modified: Date { Date(timeIntervalSince1970: Double(identity.st_mtimespec.tv_sec)) }
    var cleanupAllowed: Bool {
        !protectedByContainer && diskIsRegular(identity) && identity.st_nlink == 1 && identity.st_uid == getuid() &&
        (identity.st_flags & UInt32(UF_COMPRESSED | SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) == 0 &&
        (!scope.isWholeDisk || scope.permitsPersonalCleanup(url))
    }
    func validate(now: Date = Date()) throws {
        guard cleanupAllowed else { throw DiskError.message("此文件受保护，仅可查看。") }
        try scope.validatePath(url)
        let current = try diskStat(url)
        guard diskIsRegular(current), current.st_nlink == 1, current.st_uid == getuid(), diskSame(current, identity),
              now.timeIntervalSince(modified) >= scope.kind.age,
              scope.kind != .large || logical >= 100 * 1024 * 1024,
              (current.st_flags & UInt32(UF_COMPRESSED | SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) == 0 else {
            throw DiskError.message("文件已变化或不符合清理条件，已跳过；请重新扫描。")
        }
    }
}
final class DiskCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
struct DiskScanResult {
    var files: [DiskCandidate] = []
    var inspected = 0
    var skipped = 0
    var errors: [String] = []
    var limited = false
    var cancelled = false
    var rootFailure: String?
    var deniedPaths: [String] = []
    var excludedPaths: [String] = []
    var wholeDisk = false
    var matched = 0
    var resultsCapped = false
    var allocated: UInt64 { files.reduce(0) { $0 + $1.allocated } }
    var hasPermissionError: Bool { !deniedPaths.isEmpty }
    var statusTitle: String {
        if rootFailure != nil { return hasPermissionError ? "需要文件夹访问权限" : "无法读取扫描目录" }
        if cancelled { return "已取消，仅显示已扫描部分" }
        if limited { return "达到时间 / 数量上限，仅显示部分" }
        if hasPermissionError { return "部分文件夹无权访问" }
        if errors.isEmpty && resultsCapped { return "可访问范围扫描完成，仅显示占用最大的部分文件" }
        return errors.isEmpty ? (wholeDisk ? "可访问范围扫描完成" : "扫描完成") : "部分目录无法读取"
    }
    static func isPermissionError(_ error: Error, depth: Int = 0) -> Bool {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(e.code) { return true }
        if e.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(e.code) { return true }
        if depth < 8, let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying, depth: depth + 1)
        }
        return false
    }
    mutating func record(_ error: Error, at url: URL, root: URL) {
        if errors.count < 20 { errors.append("\(url.path)：\(error.localizedDescription)") }
        if url.standardizedFileURL.path == root.standardizedFileURL.path { rootFailure = error.localizedDescription }
        if Self.isPermissionError(error), deniedPaths.count < 20, !deniedPaths.contains(url.path) { deniedPaths.append(url.path) }
    }
}
enum DiskScanner {
    static func scan(_ scope: DiskScope, cancellation: DiskCancellation, activeBundleIDs: Set<String> = [],
                     now: Date = Date(), limit: Int? = nil, seconds: TimeInterval? = nil, resultLimit: Int = 10000,
                     progress: (Int) -> Void = { _ in }) -> DiskScanResult {
        if scope.isWholeDisk {
            return scanWholeDisk(scope, cancellation: cancellation, limit: limit ?? Int.max, seconds: seconds ?? .infinity,
                                 resultLimit: max(1, min(10000, resultLimit)), progress: progress)
        }
        let limit = limit ?? 50000, seconds = seconds ?? 25
        var result = DiskScanResult()
        let began = Date()
        let rootDevice = (try? diskStat(scope.root))?.st_dev
        do {
            let root = try diskStat(scope.root)
            guard (root.st_mode & S_IFMT) == S_IFDIR else { throw DiskError.message("扫描目录不存在或不是普通文件夹。") }
            try scope.validatePath(scope.root.appendingPathComponent("_validation_only"))
        } catch { result.record(error, at: scope.root, root: scope.root); return result }
        let keys: [URLResourceKey] = [.isPackageKey]
        guard let walker = FileManager.default.enumerator(at: scope.root, includingPropertiesForKeys: keys,
                options: [], errorHandler: { url, error in
                    result.record(error, at: url, root: scope.root)
                    return result.rootFailure == nil
                }) else {
            result.record(DiskError.message("无法打开目录；请检查目录是否存在及文件访问权限。"), at: scope.root, root: scope.root)
            return result
        }
        while let rawURL = walker.nextObject() as? URL {
            // Cocoa may enumerate /private/tmp for a root standardized as /tmp. Keep scope comparisons consistent.
            let url = rawURL.standardizedFileURL
            if cancellation.cancelled { result.cancelled = true; break }
            if result.inspected >= limit || Date().timeIntervalSince(began) >= seconds { result.limited = true; break }
            result.inspected += 1
            if result.inspected % 250 == 0 { progress(result.inspected) }
            do {
                // Inspect the original directory entry first so normalization cannot hide a symbolic link.
                let s = try diskStat(rawURL)
                if (s.st_mode & S_IFMT) == S_IFDIR {
                    let relative = url.path.dropFirst(scope.root.path.count + 1)
                    let top = String(relative.split(separator: "/").first ?? "")
                    if url.lastPathComponent.hasPrefix(".") || DiskScope.isPackage(url) || walker.level > 20 ||
                        (scope.kind != .large && activeBundleIDs.contains(top)) || s.st_dev != rootDevice {
                        walker.skipDescendants(); result.skipped += 1
                    }
                    continue
                }
                guard diskIsRegular(s), s.st_nlink == 1, s.st_uid == getuid(), !url.lastPathComponent.hasPrefix("."),
                      !DiskScope.isPackage(url), s.st_size > 0,
                      (s.st_flags & UInt32(UF_COMPRESSED | SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) == 0 else { result.skipped += 1; continue }
                let file = DiskCandidate(url: url, scope: scope, identity: s)
                guard now.timeIntervalSince(file.modified) >= scope.kind.age,
                      scope.kind != .large || file.logical >= 100 * 1024 * 1024 else { continue }
                result.files.append(file)
                // Bound UI memory as well as traversal work.
                if result.files.count >= 10000 { result.limited = true; break }
            } catch { result.skipped += 1; result.record(error, at: url, root: scope.root) }
        }
        result.files.sort { $0.allocated == $1.allocated ? $0.url.path < $1.url.path : $0.allocated > $1.allocated }
        return result
    }

    // Walk both the sealed system volume and the writable Data volume through their normal
    // startup-disk paths. /System/Volumes would duplicate Data and expose helper volumes.
    static func wholeDiskExclusion(_ url: URL, root: URL) -> Bool {
        let relative = String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
        return ["System/Volumes", "Volumes", "dev", "Network", ".vol"].contains {
            relative == $0 || relative.hasPrefix($0 + "/")
        }
    }
    private static func scanWholeDisk(_ scope: DiskScope, cancellation: DiskCancellation, limit: Int,
                                      seconds: TimeInterval, resultLimit: Int, progress: (Int) -> Void) -> DiskScanResult {
        var result = DiskScanResult(wholeDisk: true)
        let began = ProcessInfo.processInfo.systemUptime
        var pending: [(url: URL, protected: Bool)] = [(scope.root, false)]
        var directories = Set<String>(), fileIDs = Set<String>()
        let devices = Set([try? diskStat(scope.root).st_dev, try? diskStat(scope.home).st_dev].compactMap { $0 })
        func exclude(_ url: URL, _ reason: String) {
            result.skipped += 1
            if result.excludedPaths.count < 20 { result.excludedPaths.append("\(url.path)：\(reason)") }
        }
        func retainLargest() {
            result.files.sort { $0.allocated == $1.allocated ? $0.url.path < $1.url.path : $0.allocated > $1.allocated }
            if result.files.count > resultLimit { result.files.removeSubrange(resultLimit...) }
        }
        while let entry = pending.popLast() {
            let rawURL = entry.url
            if cancellation.cancelled { result.cancelled = true; break }
            if result.inspected >= limit || ProcessInfo.processInfo.systemUptime - began >= seconds { result.limited = true; break }
            let url = rawURL.standardizedFileURL
            result.inspected += 1
            if result.inspected % 500 == 0 { progress(result.inspected) }
            autoreleasepool {
                do {
                    let s = try diskStat(rawURL)
                    let isRoot = url.path == scope.root.path
                    let directory = (s.st_mode & S_IFMT) == S_IFDIR
                    if isRoot && !directory { throw DiskError.message("扫描入口不是普通文件夹。") }
                    if !isRoot && wholeDiskExclusion(url, root: scope.root) { exclude(url, "外置 / 网络 / 辅助卷或重复入口，未扫描"); return }
                    guard devices.contains(s.st_dev) else { exclude(url, "其他挂载设备，未扫描"); return }
                    guard (s.st_flags & UInt32(SF_DATALESS)) == 0 else { exclude(url, "云端占位，未下载"); return }
                    let identity = "\(s.st_dev):\(s.st_ino)"
                    if directory {
                        guard directories.insert(identity).inserted else { exclude(url, "重复目录入口"); return }
                        var children = try FileManager.default.contentsOfDirectory(at: rawURL, includingPropertiesForKeys: [], options: [])
                        // Prioritize personal files before potentially large system directory trees.
                        if diskContains(scope.home.path, in: url.path) {
                            children.sort {
                                let a = scope.home.path == $0.standardizedFileURL.path || diskContains(scope.home.path, in: $0.standardizedFileURL.path)
                                let b = scope.home.path == $1.standardizedFileURL.path || diskContains(scope.home.path, in: $1.standardizedFileURL.path)
                                return a == b ? $0.path > $1.path : !a && b
                            }
                        }
                        let protected = entry.protected || DiskScope.isPackage(url)
                        pending.append(contentsOf: children.map { ($0, protected) })
                    } else if diskIsRegular(s), s.st_size >= 100 * 1024 * 1024, fileIDs.insert(identity).inserted {
                        // Include hidden/package/system files for inspection. Cleanup is independently restricted.
                        result.matched += 1
                        result.files.append(DiskCandidate(url: url, scope: scope, identity: s, protectedByContainer: entry.protected))
                        // Bound retained metadata, but continue traversing the entire volume.
                        if result.files.count >= resultLimit * 2 { retainLargest() }
                    } else { result.skipped += 1 }
                } catch { result.skipped += 1; result.record(error, at: url, root: scope.root) }
            }
        }
        retainLargest(); result.resultsCapped = result.matched > resultLimit
        return result
    }
}
struct DiskTrashResult {
    var moved: [DiskCandidate] = []
    var errors: [String] = []
    var allocated: UInt64 { moved.reduce(0) { $0 + $1.allocated } }
}
enum DiskCleaner {
    static func trashSelection(_ files: [DiskCandidate], activeBundleIDs: Set<String> = [], mover: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) -> DiskTrashResult {
        // One explicit confirmation covers the full selection; each internal batch retains its bound.
        guard files.count <= 10000 else { return DiskTrashResult(errors: ["选择超出单次扫描的 10,000 项上限，请重新扫描。"]) }
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.url.path).inserted }
        var result = DiskTrashResult()
        for offset in stride(from: 0, to: unique.count, by: 1000) {
            let batch = Array(unique[offset..<min(offset + 1000, unique.count)])
            let outcome = trash(batch, activeBundleIDs: activeBundleIDs, mover: mover)
            result.moved.append(contentsOf: outcome.moved); result.errors.append(contentsOf: outcome.errors)
        }
        return result
    }
    static func trash(_ files: [DiskCandidate], activeBundleIDs: Set<String> = [], mover: (URL) throws -> Void = { url in
        // No permanent-delete fallback, even if the system Trash operation fails.
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) -> DiskTrashResult {
        var result = DiskTrashResult()
        guard files.count <= 1000 else { result.errors = ["每批最多处理 1,000 个文件，请减少选择。"]; return result }
        var seen = Set<String>()
        for file in files {
            guard seen.insert(file.url.path).inserted else { continue }
            do {
                if file.scope.kind != .large {
                    let relative = file.url.path.dropFirst(file.scope.root.path.count + 1)
                    if activeBundleIDs.contains(String(relative.split(separator: "/").first ?? "")) {
                        throw DiskError.message("相关应用仍在运行，请退出后重新扫描。")
                    }
                }
                try file.validate(); try mover(file.url); result.moved.append(file)
            }
            catch { result.errors.append("\(file.url.path)：\(error.localizedDescription)") }
        }
        return result
    }
}
struct DiskCapacity {
    let total: UInt64
    let free: UInt64
    static func read(at url: URL) -> DiskCapacity? {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let total = a[.systemSize] as? NSNumber, let free = a[.systemFreeSize] as? NSNumber else { return nil }
        return DiskCapacity(total: total.uint64Value, free: free.uint64Value)
    }
}
