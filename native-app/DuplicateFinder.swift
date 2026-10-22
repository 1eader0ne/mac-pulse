import Foundation
import CryptoKit
import Darwin

struct DuplicateEntry {
    let url: URL
    let scope: DiskScope
    let identity: stat
    var size: UInt64 { UInt64(max(0, identity.st_size)) }
    var allocated: UInt64 { UInt64(max(0, identity.st_blocks)) * 512 }
    func validate() throws {
        try scope.validatePath(url)
        let current = try diskStat(url)
        guard !scope.isWholeDisk, scope.kind == .large, diskSame(current, identity),
              DuplicateScanner.eligible(current, url: url) else {
            throw DiskError.message("文件已变化或不符合保护条件，请重新查找。")
        }
    }
}
struct DuplicateGroup {
    let digest: String
    let files: [DuplicateEntry]
    var redundant: [DuplicateEntry] { Array(files.dropFirst()) }
}
struct DuplicateResult {
    var groups: [DuplicateGroup] = []
    var inspected = 0, hashed = 0, skipped = 0
    var bytesRead: UInt64 = 0
    var cancelled = false, limited = false
    var errors: [String] = []
    var rootFailure = false
    var redundant: [DuplicateEntry] { groups.flatMap(\.redundant) }
    var status: String {
        if rootFailure { return "无法读取所选目录，请检查文件夹权限。" }
        if cancelled { return "已取消，仅显示已核对的部分结果。" }
        if limited { return "达到扫描 / 内容读取上限，仅显示部分结果；可选择较小的文件夹重试。" }
        if !errors.isEmpty { return "部分文件无法核对，结果不完整。" }
        return "查找完成。"
    }
    mutating func record(_ error: Error, at url: URL) {
        if errors.count < 20 { errors.append("\(url.path)：\(error.localizedDescription)") }
    }
}
enum DuplicateStop: Error { case cancelled, limit }
final class DuplicateBudget {
    let cancellation: DiskCancellation
    let began = ProcessInfo.processInfo.systemUptime
    let seconds: TimeInterval
    let byteLimit: UInt64
    var bytes: UInt64 = 0
    init(_ token: DiskCancellation, seconds: TimeInterval = 120, byteLimit: UInt64 = 20 * 1024 * 1024 * 1024) {
        cancellation = token; self.seconds = seconds; self.byteLimit = byteLimit
    }
    func check() throws {
        if cancellation.cancelled { throw DuplicateStop.cancelled }
        if ProcessInfo.processInfo.systemUptime - began >= seconds { throw DuplicateStop.limit }
    }
    func read(_ handle: FileHandle) throws -> Data {
        try check()
        // Reading at most the remaining allowance avoids silently exceeding the I/O budget.
        guard bytes < byteLimit else { throw DuplicateStop.limit }
        let data = try handle.read(upToCount: Int(min(1024 * 1024, byteLimit - bytes))) ?? Data()
        bytes += UInt64(data.count); return data
    }
}
enum DuplicateScanner {
    static func eligible(_ s: stat, url: URL) -> Bool {
        guard diskIsRegular(s), s.st_size > 0, s.st_nlink == 1, s.st_uid == getuid(),
              (s.st_flags & UInt32(UF_COMPRESSED | SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) == 0 else { return false }
        // Resource forks can carry distinct content even when ordinary data bytes match.
        let length = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        return length == 0 || (length < 0 && errno == ENOATTR)
    }
    private static func openFile(_ file: DuplicateEntry) throws -> FileHandle {
        try file.validate()
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try unchanged(handle, file); return handle } catch { try? handle.close(); throw error }
    }
    private static func unchanged(_ handle: FileHandle, _ file: DuplicateEntry) throws {
        var s = stat()
        guard fstat(handle.fileDescriptor, &s) == 0, diskSame(s, file.identity), diskIsRegular(s), s.st_nlink == 1 else {
            throw DiskError.message("读取期间文件发生变化，已跳过。")
        }
    }
    static func digest(_ file: DuplicateEntry, budget: DuplicateBudget) throws -> String {
        let handle = try openFile(file); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let count = try autoreleasepool { () throws -> Int in
                let data = try budget.read(handle); hash.update(data: data); return data.count
            }
            if count == 0 { break }
        }
        try unchanged(handle, file); try file.validate()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func equal(_ a: DuplicateEntry, _ b: DuplicateEntry, budget: DuplicateBudget) throws -> Bool {
        guard a.size == b.size else { return false }
        let left = try openFile(a); defer { try? left.close() }
        let right = try openFile(b); defer { try? right.close() }
        while true {
            let outcome = try autoreleasepool { () throws -> (Bool, Bool) in
                let x = try budget.read(left), y = try budget.read(right)
                return (x == y, x.isEmpty && y.isEmpty)
            }
            if !outcome.0 { return false }
            if outcome.1 { break }
        }
        try unchanged(left, a); try unchanged(right, b)
        try a.validate(); try b.validate(); return true
    }
    static func find(_ scope: DiskScope, cancellation: DiskCancellation, limit: Int = 50000,
                     seconds: TimeInterval = 120, byteLimit: UInt64 = 20 * 1024 * 1024 * 1024,
                     progress: (String) -> Void = { _ in }) -> DuplicateResult {
        var result = DuplicateResult()
        let budget = DuplicateBudget(cancellation, seconds: seconds, byteLimit: byteLimit)
        var sizes: [Int64: [DuplicateEntry]] = [:]
        do {
            guard !scope.isWholeDisk, scope.kind == .large,
                  (try diskStat(scope.root)).st_mode & S_IFMT == S_IFDIR else { throw DiskError.message("请选择个人文件夹。") }
            try scope.validatePath(scope.root.appendingPathComponent("_validation_only"))
        } catch { result.rootFailure = true; result.record(error, at: scope.root); return result }
        let device = (try? diskStat(scope.root))?.st_dev
        guard let walker = FileManager.default.enumerator(at: scope.root, includingPropertiesForKeys: [.isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                if url.standardizedFileURL.path == scope.root.path { result.rootFailure = true }
                result.record(error, at: url); return true
            }) else { result.rootFailure = true; return result }
        do {
            while let raw = walker.nextObject() as? URL {
                try budget.check()
                if result.inspected >= limit { result.limited = true; break }
                result.inspected += 1
                if result.inspected % 250 == 0 { progress("按大小筛选：已检查 \(result.inspected) 项") }
                let url = raw.standardizedFileURL
                do {
                    let s = try diskStat(raw)
                    if (s.st_mode & S_IFMT) == S_IFDIR {
                        if s.st_dev != device || DiskScope.isPackage(url) || walker.level > 64 ||
                            (s.st_flags & UInt32(SF_DATALESS)) != 0 {
                            walker.skipDescendants(); result.skipped += 1
                            if walker.level > 64 { result.limited = true }
                        }
                    } else if eligible(s, url: raw), !DiskScope.isPackage(url) {
                        sizes[Int64(s.st_size), default: []].append(DuplicateEntry(url: url, scope: scope, identity: s))
                    } else { result.skipped += 1 }
                } catch { result.record(error, at: url) }
            }
            var hashes: [String: [DuplicateEntry]] = [:]
            for size in sizes.keys.sorted() where (sizes[size]?.count ?? 0) > 1 {
                for file in sizes[size]!.sorted(by: { $0.url.path < $1.url.path }) {
                    try budget.check()
                    do {
                        let hash = try digest(file, budget: budget); result.hashed += 1
                        hashes[hash, default: []].append(file)
                        if result.hashed % 10 == 0 { progress("校验内容：\(result.hashed) 个文件 · 读取 \(byteText(budget.bytes))") }
                    } catch let stop as DuplicateStop { throw stop }
                    catch { result.record(error, at: file.url) }
                }
            }
            for key in hashes.keys.sorted() where hashes[key]!.count > 1 {
                // SHA-256 narrows candidates; byte comparison establishes actual data equality.
                var verified: [[DuplicateEntry]] = []
                for file in hashes[key]!.sorted(by: { $0.url.path < $1.url.path }) {
                    try budget.check()
                    do {
                        var match: Int?
                        for i in verified.indices {
                            if try equal(verified[i][0], file, budget: budget) { match = i; break }
                        }
                        if let i = match { verified[i].append(file) } else { verified.append([file]) }
                    } catch let stop as DuplicateStop { throw stop }
                    catch { result.record(error, at: file.url) }
                }
                result.groups.append(contentsOf: verified.filter { $0.count > 1 }.map { DuplicateGroup(digest: key, files: $0) })
            }
        } catch DuplicateStop.cancelled { result.cancelled = true }
        catch { result.limited = true }
        result.bytesRead = budget.bytes
        result.groups.sort { $0.files[0].size == $1.files[0].size ? $0.files[0].url.path < $1.files[0].url.path : $0.files[0].size > $1.files[0].size }
        return result
    }
}
struct DuplicateTrashResult {
    var moved: [URL] = []
    var errors: [String] = []
}
enum DuplicateCleaner {
    static func trash(_ groups: [DuplicateGroup], selected: Set<String>,
                      mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> DuplicateTrashResult {
        var result = DuplicateTrashResult()
        guard selected.count <= 1000 else { result.errors = ["每次最多处理 1,000 个副本。"]; return result }
        var paths = Set<String>(), identities = Set<String>()
        for group in groups {
            guard group.files.count > 1 else { result.errors = ["重复分组无效，请重新查找。"]; return result }
            for file in group.files {
                guard paths.insert(file.url.path).inserted,
                      identities.insert("\(file.identity.st_dev):\(file.identity.st_ino)").inserted else {
                    result.errors = ["分组存在重复路径或文件身份，请重新查找。"]; return result
                }
            }
        }
        let allowed = Set(groups.flatMap(\.redundant).map { $0.url.path })
        let keepers = Set(groups.compactMap { $0.files.first?.url.path })
        guard selected.isSubset(of: allowed), selected.isDisjoint(with: keepers) else {
            result.errors = ["保留文件或扫描范围外的文件不能清理。"]; return result
        }
        let budget = DuplicateBudget(DiskCancellation())
        var seen = Set<String>()
        for group in groups {
            guard let keeper = group.files.first else { continue }
            for file in group.redundant where selected.contains(file.url.path) && seen.insert(file.url.path).inserted {
                do {
                    guard try DuplicateScanner.digest(keeper, budget: budget) == group.digest,
                          try DuplicateScanner.digest(file, budget: budget) == group.digest,
                          try DuplicateScanner.equal(keeper, file, budget: budget) else {
                        throw DiskError.message("保留文件或副本内容已变化，请重新查找。")
                    }
                    try keeper.validate(); try file.validate()
                    try mover(file.url); result.moved.append(file.url)
                } catch { result.errors.append("\(file.url.path)：\(error.localizedDescription)") }
            }
        }
        return result
    }
}
