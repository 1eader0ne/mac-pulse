import AppKit
import CryptoKit
import Darwin

struct UninstallEnvironment {
    let home: URL
    let applicationRoots: [URL]
    var resolveApplication: (String) -> URL?
    var isRunning: (String, URL?) -> Bool
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationRoots: [URL]? = nil,
         resolveApplication: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         isRunning: @escaping (String, URL?) -> Bool = UninstallEnvironment.liveRunning) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.resolveApplication = resolveApplication; self.isRunning = isRunning
    }
    static func liveRunning(_ id: String, _ app: URL?) -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == id || (app != nil && [$0.bundleURL, $0.executableURL].compactMap { $0 }.contains {
                $0.path == app!.path || diskContains($0.path, in: app!.path)
            })
        }) { return true }
        guard let app = app else { return false }
        // Include unregistered helper processes executing inside the application bundle.
        var rows = [MPProcess](repeating: MPProcess(), count: 16384)
        let count = mp_processes(&rows, Int32(rows.count))
        guard count >= 0, Int(count) < rows.count else { return true } // Fail closed if process coverage is incomplete.
        return rows.prefix(Int(count)).contains { diskContains(cString($0.path), in: app.path) }
    }
    func appRoot(for url: URL) -> URL? {
        applicationRoots.first { diskContains(url.path, in: $0.standardizedFileURL.path) }
    }
}
enum UninstallPolicy {
    static func validIdentifier(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return id.utf8.count <= 255 && id.split(separator: ".", omittingEmptySubsequences: false).count >= 2 &&
            !id.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == ".." }) &&
            id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    static func protectedIdentifier(_ id: String) -> Bool {
        id.lowercased() == productID.lowercased() || id.lowercased() == "com.apple" || id.lowercased().hasPrefix("com.apple.")
    }
    static func ancestors(_ url: URL, within root: URL) throws {
        guard url.path == url.standardizedFileURL.path, diskContains(url.path, in: root.path) else {
            throw DiskError.message("路径超出允许范围。")
        }
        var cursor = url.deletingLastPathComponent()
        while true {
            let s = try diskStat(cursor)
            guard (s.st_mode & S_IFMT) == S_IFDIR, cursor.path == cursor.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw DiskError.message("上级目录是链接或已变化，已拒绝操作。")
            }
            if cursor.path == root.path { break }
            guard diskContains(cursor.path, in: root.path) else { throw DiskError.message("路径超出允许范围。") }
            cursor.deleteLastPathComponent()
        }
    }
}
struct UninstallApplication {
    let url: URL
    let identifier: String
    let name: String
    let identity: stat
    let infoDigest: String
    static func read(_ raw: URL, environment: UninstallEnvironment) throws -> UninstallApplication {
        let url = raw.standardizedFileURL
        guard url.pathExtension.lowercased() == "app", let root = environment.appRoot(for: url) else {
            throw DiskError.message("仅支持 /Applications 或当前用户 Applications 内的普通 .app；系统目录与链接应用请用原安装工具管理。")
        }
        try UninstallPolicy.ancestors(url, within: root.standardizedFileURL)
        var parent = url.deletingLastPathComponent()
        while parent.path != root.standardizedFileURL.path {
            guard parent.pathExtension.lowercased() != "app" else { throw DiskError.message("不能单独卸载应用内部的辅助程序。") }
            parent.deleteLastPathComponent()
        }
        let identity = try diskStat(url)
        guard (identity.st_mode & S_IFMT) == S_IFDIR,
              (identity.st_flags & UInt32(SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) == 0 else {
            throw DiskError.message("应用不是普通目录、尚未下载或受到文件保护。")
        }
        let info = url.appendingPathComponent("Contents/Info.plist")
        try UninstallPolicy.ancestors(info, within: url)
        let infoStat = try diskStat(info)
        guard diskIsRegular(infoStat), infoStat.st_size <= 512 * 1024,
              (infoStat.st_flags & UInt32(SF_DATALESS)) == 0 else { throw DiskError.message("应用信息无效或尚未下载。") }
        let fd = open(info.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, diskSame(opened, infoStat) else { throw DiskError.message("应用信息已变化。") }
        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
        var after = stat()
        guard data.count <= 512 * 1024, fstat(fd, &after) == 0, diskSame(after, infoStat) else {
            throw DiskError.message("读取期间应用信息发生变化或超出上限。")
        }
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = dictionary["CFBundleIdentifier"] as? String, UninstallPolicy.validIdentifier(id),
              dictionary["CFBundlePackageType"] as? String == "APPL" else {
            throw DiskError.message("应用缺少有效标识或不是标准应用包。")
        }
        let name = dictionary["CFBundleDisplayName"] as? String ?? dictionary["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        return UninstallApplication(url: url, identifier: id, name: String(name.prefix(100)), identity: identity,
            infoDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    func validate(_ environment: UninstallEnvironment) throws {
        let current = try Self.read(url, environment: environment)
        guard diskSame(current.identity, identity), current.identifier == identifier, current.infoDigest == infoDigest else {
            throw DiskError.message("应用已更新、替换或移动，请重新检查。")
        }
    }
}
struct UninstallCatalog {
    var applications: [UninstallApplication] = []
    var errors: [String] = []
    var complete = true
    static func read(_ environment: UninstallEnvironment, cancellation: DiskCancellation = DiskCancellation()) -> UninstallCatalog {
        var result = UninstallCatalog(), seen = Set<String>()
        var pending = environment.applicationRoots.map { ($0.standardizedFileURL, 0) }
        var inspected = 0
        while let (url, depth) = pending.popLast() {
            if cancellation.cancelled || inspected >= 10000 { result.complete = false; break }
            inspected += 1
            do {
                let s = try diskStat(url)
                guard (s.st_mode & S_IFMT) == S_IFDIR else { continue }
                if url.pathExtension.lowercased() == "app" {
                    do {
                        let app = try UninstallApplication.read(url, environment: environment)
                        if seen.insert(app.url.path).inserted { result.applications.append(app) }
                    } catch {
                        // A malformed bundle cannot establish that a matching residue is orphaned.
                        result.complete = false
                        if result.errors.count < 20 { result.errors.append("\(url.path)：\(error.localizedDescription)") }
                    }
                } else {
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])
                    if depth < 3 { pending.append(contentsOf: children.map { ($0, depth + 1) }) }
                    else if children.contains(where: { $0.pathExtension.lowercased() == "app" }) { result.complete = false }
                }
            } catch {
                if (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOENT) { continue }
                result.complete = false
                if result.errors.count < 20 { result.errors.append("\(url.path)：\(error.localizedDescription)") }
            }
        }
        result.applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
}
struct UninstallTarget {
    let identifier: String
    let name: String
    let application: UninstallApplication?
    var orphan: Bool { application == nil }
    init(application: UninstallApplication) { identifier = application.identifier; name = application.name; self.application = application }
    init(identifier: String) { self.identifier = identifier; name = identifier; application = nil }
}
enum UninstallKind: CaseIterable {
    case application, cache, preferences, logs, savedState, httpStorage, webKit, support, container, agent, nameMatch
    var title: String {
        switch self {
        case .application: return "应用本体"
        case .cache: return "缓存"
        case .preferences: return "偏好设置"
        case .logs: return "日志"
        case .savedState: return "窗口状态"
        case .httpStorage: return "网站 / 登录数据"
        case .webKit: return "网页数据"
        case .support: return "应用数据（需备份）"
        case .container: return "沙盒数据（仅查看）"
        case .agent: return "后台服务（仅查看）"
        case .nameMatch: return "名称匹配（仅查看）"
        }
    }
    var directory: String? {
        switch self {
        case .cache: return "Caches"
        case .preferences: return "Preferences"
        case .logs: return "Logs"
        case .savedState: return "Saved Application State"
        case .httpStorage: return "HTTPStorages"
        case .webKit: return "WebKit"
        case .support, .nameMatch: return "Application Support"
        case .container: return "Containers"
        case .agent: return "LaunchAgents"
        case .application: return nil
        }
    }
    func path(for id: String, home: URL) -> URL? {
        guard let directory = directory, self != .nameMatch else { return nil }
        let suffix = self == .preferences || self == .agent ? ".plist" : self == .savedState ? ".savedState" : ""
        return home.appendingPathComponent("Library/\(directory)/\(id)\(suffix)")
    }
    var inspectOnly: Bool { self == .container || self == .agent || self == .nameMatch }
}
struct UninstallTree {
    var logical: UInt64 = 0, allocated: UInt64 = 0
    var entries = 0
    var digest = ""
    var complete = true
    var note = ""
    static func read(_ root: URL, cancellation: DiskCancellation, limit: Int = 100000, seconds: TimeInterval = 30) -> UninstallTree {
        var result = UninstallTree(), records: [String] = [], fileIDs = Set<String>()
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let rootStat = try diskStat(root)
            guard diskIsRegular(rootStat) || (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw DiskError.message("不处理链接或特殊文件。") }
            guard (rootStat.st_flags & UInt32(SF_DATALESS)) == 0 else { throw DiskError.message("根目录是云端占位，不下载内容。") }
            func record(_ url: URL, _ s: stat) {
                result.entries += 1
                records.append("\(url.path.dropFirst(root.path.count))|\(s.st_dev)|\(s.st_ino)|\(s.st_mode)|\(s.st_uid)|\(s.st_flags)|\(s.st_size)|\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)|\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)")
                if (s.st_flags & UInt32(SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE)) != 0 {
                    result.complete = false; result.note = "包含云端占位或受保护项，未完整统计。"
                }
                if diskIsRegular(s), fileIDs.insert("\(s.st_dev):\(s.st_ino)").inserted {
                    result.logical += UInt64(max(0, s.st_size)); result.allocated += UInt64(max(0, s.st_blocks)) * 512
                }
            }
            record(root, rootStat)
            if (rootStat.st_mode & S_IFMT) == S_IFDIR {
                guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [], errorHandler: { _, error in
                    result.complete = false; result.note = "部分目录无权访问：\(error.localizedDescription)"; return true
                }) else { throw DiskError.message("无法遍历目录。") }
                while let raw = walker.nextObject() as? URL {
                    if cancellation.cancelled || result.entries >= limit || ProcessInfo.processInfo.systemUptime - began >= seconds {
                        result.complete = false; result.note = cancellation.cancelled ? "已取消统计。" : "达到统计上限。"; break
                    }
                    autoreleasepool {
                        do {
                            let s = try diskStat(raw), url = raw.standardizedFileURL
                            if s.st_dev != rootStat.st_dev { walker.skipDescendants(); result.complete = false; result.note = "目录包含其他挂载设备。"; return }
                            record(url, s)
                            if (s.st_flags & UInt32(SF_DATALESS)) != 0 { walker.skipDescendants() }
                        } catch { result.complete = false; result.note = error.localizedDescription }
                    }
                }
            }
            if cancellation.cancelled { result.complete = false; result.note = "已取消统计。" }
            var hash = SHA256()
            for line in records.sorted() { hash.update(data: Data((line + "\n").utf8)) }
            result.digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { result.complete = false; result.note = error.localizedDescription }
        return result
    }
}
struct UninstallItem {
    let url: URL
    let kind: UninstallKind
    let tree: UninstallTree?
    let protectedReason: String?
    var selectable: Bool { protectedReason == nil && tree?.complete == true && !kind.inspectOnly }
    var basis: String { kind == .application ? "所选应用包" : kind == .nameMatch ? "仅名称相似，归属未确认" : "完整应用标识精确匹配" }
}
struct UninstallReport {
    let target: UninstallTarget
    var items: [UninstallItem] = []
    var errors: [String] = []
    var cancelled = false
    var protection: String?
    var text: String {
        "\(target.orphan ? "疑似残留" : "应用检查")：\(target.name)\n标识：\(target.identifier)\n" +
        (protection.map { "保护：\($0)\n" } ?? "") +
        items.map { "\($0.kind.title) · \($0.url.path)\n依据：\($0.basis)\n\($0.protectedReason ?? "可勾选，操作前重新校验")" }.joined(separator: "\n\n") +
        "\n\n" + errors.joined(separator: "\n") +
        "\n\n默认不选择。应用数据可能含数据库、登录和配置，请先备份。未找到应用不等于残留无用；扫描不覆盖共享容器、钥匙串、系统扩展、安装收据或所有自定义位置。带官方卸载器的软件请优先使用官方卸载器。"
    }
}
struct UninstallResidues {
    var targets: [UninstallTarget] = []
    var errors: [String] = []
}
enum UninstallScanner {
    static func relatedInstalledIdentifier(_ id: String, catalog: UninstallCatalog) -> Bool {
        let candidate = id.lowercased()
        return catalog.applications.contains {
            let installed = $0.identifier.lowercased()
            return installed == candidate || candidate.hasPrefix(installed + ".") || installed.hasPrefix(candidate + ".")
        }
    }
    static func appExists(_ id: String, catalog: UninstallCatalog, environment: UninstallEnvironment, excluding: URL? = nil) -> Bool {
        if catalog.applications.contains(where: { $0.identifier == id && $0.url.path != excluding?.path }) { return true }
        if let url = environment.resolveApplication(id), url.path != excluding?.path, FileManager.default.fileExists(atPath: url.path) { return true }
        return false
    }
    static func contextProtection(_ target: UninstallTarget, environment: UninstallEnvironment,
                                  catalog: UninstallCatalog) -> String? {
        if !UninstallPolicy.validIdentifier(target.identifier) || UninstallPolicy.protectedIdentifier(target.identifier) {
            return "系统应用、轻诊自身或无效应用标识受到保护。"
        }
        if environment.isRunning(target.identifier, target.application?.url) { return "应用或辅助进程仍在运行，请先退出后重新检查。" }
        if target.orphan && (!catalog.complete || relatedInstalledIdentifier(target.identifier, catalog: catalog) ||
            appExists(target.identifier, catalog: catalog, environment: environment)) {
            return "已找到对应应用，或应用清单不完整，不能作为已卸载应用的残留处理。"
        }
        return nil
    }
    static func residues(_ environment: UninstallEnvironment, cancellation: DiskCancellation) -> UninstallResidues {
        let catalog = UninstallCatalog.read(environment, cancellation: cancellation)
        var result = UninstallResidues(errors: catalog.errors), ids = Set<String>(), inspected = 0
        for kind in [UninstallKind.cache, .preferences, .logs, .savedState, .httpStorage, .webKit, .support] {
            if cancellation.cancelled { break }
            let directory = environment.home.appendingPathComponent("Library/\(kind.directory!)")
            do {
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])
                for url in children {
                    inspected += 1
                    if inspected > 10000 || cancellation.cancelled { break }
                    var id = url.lastPathComponent
                    if kind == .preferences { guard id.hasSuffix(".plist") else { continue }; id = String(id.dropLast(6)) }
                    if kind == .savedState { guard id.hasSuffix(".savedState") else { continue }; id = String(id.dropLast(11)) }
                    if UninstallPolicy.validIdentifier(id), !UninstallPolicy.protectedIdentifier(id),
                       !relatedInstalledIdentifier(id, catalog: catalog),
                       !appExists(id, catalog: catalog, environment: environment), !environment.isRunning(id, nil) { ids.insert(id) }
                }
            } catch {
                if (error as NSError).code != Int(ENOENT), (error as NSError).code != NSFileReadNoSuchFileError,
                   result.errors.count < 20 { result.errors.append("\(directory.path)：\(error.localizedDescription)") }
            }
        }
        if !catalog.complete { result.errors.append("应用清单未完整读取；候选仅供查看，暂不可清理。") }
        if inspected > 10000 { result.errors.append("达到候选检查上限，仅显示部分。") }
        result.targets = ids.sorted().prefix(500).map { UninstallTarget(identifier: $0) }
        if ids.count > 500 { result.errors.append("最多显示 500 个疑似残留标识。") }
        return result
    }
    static func scan(_ target: UninstallTarget, environment: UninstallEnvironment, cancellation: DiskCancellation,
                     treeLimit: Int = 100000, treeSeconds: TimeInterval = 30) -> UninstallReport {
        var result = UninstallReport(target: target)
        let catalog = UninstallCatalog.read(environment, cancellation: cancellation)
        result.protection = contextProtection(target, environment: environment, catalog: catalog)
        if let app = target.application {
            do { try app.validate(environment) } catch { result.protection = error.localizedDescription }
        }
        let sharedCopy = !target.orphan && appExists(target.identifier, catalog: catalog, environment: environment, excluding: target.application?.url)
        var expected: [(URL, UninstallKind)] = []
        if let app = target.application { expected.append((app.url, .application)) }
        for kind in UninstallKind.allCases where kind != .application && kind != .nameMatch {
            if let url = kind.path(for: target.identifier, home: environment.home) { expected.append((url, kind)) }
        }
        if let app = target.application {
            for name in Set([app.name, app.url.deletingPathExtension().lastPathComponent]) where !name.isEmpty && !name.contains("/") && name != "." && name != ".." {
                expected.append((environment.home.appendingPathComponent("Library/Application Support/\(name)"), .nameMatch))
            }
        }
        var seen = Set<String>()
        for (url, kind) in expected {
            if cancellation.cancelled { result.cancelled = true; break }
            guard seen.insert(url.path).inserted else { continue }
            do {
                guard let root = kind == .application ? environment.appRoot(for: url) : environment.home else {
                    throw DiskError.message("应用不在允许目录内。")
                }
                try UninstallPolicy.ancestors(url, within: root.standardizedFileURL)
                let s = try diskStat(url)
                var reason = result.protection
                if kind.inspectOnly { reason = "沙盒文档、后台服务或仅名称匹配的目录不自动处理，请核对后使用官方卸载器或 Finder。" }
                if kind != .application && sharedCopy { reason = "还有相同标识的另一份应用，关联数据可能共用。" }
                if kind != .application && s.st_uid != getuid() { reason = "文件不属于当前用户。" }
                if (s.st_mode & S_IFMT) == S_IFLNK { reason = "链接仅查看，不跟随或移动。" }
                let tree = reason == nil ? UninstallTree.read(url, cancellation: cancellation, limit: treeLimit, seconds: treeSeconds) : nil
                if let tree = tree, !tree.complete { reason = tree.note }
                result.items.append(UninstallItem(url: url, kind: kind, tree: tree, protectedReason: reason))
            } catch {
                let e = error as NSError
                if !(e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)), result.errors.count < 20 {
                    result.errors.append("\(url.path)：\(error.localizedDescription)")
                }
            }
        }
        result.cancelled = cancellation.cancelled
        return result
    }
}
struct UninstallTrashResult {
    var moved: [URL] = []
    var errors: [String] = []
}
enum UninstallCleaner {
    static func trash(_ report: UninstallReport, selected: Set<String>, environment: UninstallEnvironment,
                      mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> UninstallTrashResult {
        var result = UninstallTrashResult()
        guard !report.cancelled, report.protection == nil, !selected.isEmpty, selected.count <= 20 else {
            result.errors = ["检查未完成、目标受保护或选择无效，请重新检查。"]; return result
        }
        let items = report.items.filter { selected.contains($0.url.path) }
        guard Set(items.map { $0.url.path }) == selected, items.count == selected.count, items.allSatisfy(\.selectable) else {
            result.errors = ["选择包含保护项或检查范围外路径。"]; return result
        }
        // Process data first, application last. App identity remains available throughout verification.
        let ordered = items.sorted { ($0.kind == .application ? 1 : 0) < ($1.kind == .application ? 1 : 0) }
        for item in ordered {
            do {
                let catalog = UninstallCatalog.read(environment)
                if let protection = UninstallScanner.contextProtection(report.target, environment: environment, catalog: catalog) {
                    throw DiskError.message(protection)
                }
                if let app = report.target.application { try app.validate(environment) }
                if item.kind == .application {
                    guard let app = report.target.application, app.url.path == item.url.path else { throw DiskError.message("应用路径不匹配。") }
                    guard let root = environment.appRoot(for: item.url) else { throw DiskError.message("应用不在允许目录内。") }
                    try UninstallPolicy.ancestors(item.url, within: root)
                } else {
                    guard !item.kind.inspectOnly, item.kind.path(for: report.target.identifier, home: environment.home)?.path == item.url.path else {
                        throw DiskError.message("不允许处理此关联路径。")
                    }
                    guard !UninstallScanner.appExists(report.target.identifier, catalog: catalog, environment: environment,
                        excluding: report.target.application?.url) else { throw DiskError.message("相同标识的其他应用仍存在，关联数据可能共享。") }
                    try UninstallPolicy.ancestors(item.url, within: environment.home)
                    guard (try diskStat(item.url)).st_uid == getuid() else { throw DiskError.message("归属发生变化。") }
                }
                let current = UninstallTree.read(item.url, cancellation: DiskCancellation())
                guard current.complete, current.digest == item.tree?.digest else { throw DiskError.message("文件树已变化或未完整核对，请重新检查。") }
                if environment.isRunning(report.target.identifier, report.target.application?.url) { throw DiskError.message("应用已重新运行，已跳过。") }
                try mover(item.url); result.moved.append(item.url)
            } catch { result.errors.append("\(item.url.path)：\(error.localizedDescription)") }
        }
        return result
    }
}
