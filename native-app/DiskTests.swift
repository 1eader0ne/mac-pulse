import Foundation
import Darwin
import AppKit

// Every mutable path in this suite is created in this uniquely named fixture tree.
func diskSelfTest() {
    let fm = FileManager.default
    // Keep identity-sensitive fixtures away from document-sync providers that may change metadata.
    let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let fixture = parent.appendingPathComponent("MacPulseDiskFixture-" + UUID().uuidString)
    var checks = 0, failures = 0
    func check(_ condition: Bool, _ name: String) {
        checks += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") disk: \(name)")
    }
    do {
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        let cache = home.appendingPathComponent("Library/Caches")
        let logs = home.appendingPathComponent("Library/Logs")
        let downloads = home.appendingPathComponent("Downloads")
        for u in [cache, logs, downloads] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        func make(_ url: URL, days: Double = 90, data: String = "test-owned disk fixture\n") throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
        }
        func candidate(_ url: URL, _ scope: DiskScope) throws -> DiskCandidate { DiskCandidate(url: url, scope: scope, identity: try diskStat(url)) }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let scope = try DiskScope(root: cache, kind: .caches, home: home)
        check(diskContains(cache.path + "/x", in: cache.path) && !diskContains(cache.path + "-other/x", in: cache.path), "path component boundary")
        check(rejects { _ = try DiskScope(root: home, kind: .large, home: home) }, "reject entire home")
        check(rejects { _ = try DiskScope(root: home.appendingPathComponent("Library/Keychains"), kind: .large, home: home) }, "protect private Library")
        check(rejects { _ = try DiskScope(root: downloads, kind: .caches, home: home) }, "cache scope cannot target personal files")
        check(rejects { _ = try DiskScope(root: fixture, kind: .large, home: home) }, "reject outside user scope")
        let old = cache.appendingPathComponent("old.cache"), fresh = cache.appendingPathComponent("fresh.cache")
        let active = cache.appendingPathComponent("com.test.active/data.cache")
        let package = cache.appendingPathComponent("Preserve.app/data.cache")
        let hidden = cache.appendingPathComponent(".private/data.cache")
        for u in [old, active, package, hidden] { try make(u) }; try make(fresh, days: 1)
        let linked = cache.appendingPathComponent("linked.cache")
        try fm.createSymbolicLink(at: linked, withDestinationURL: old)
        let hard = cache.appendingPathComponent("hard.cache"), hard2 = cache.appendingPathComponent("hard2.cache")
        try make(hard); try fm.linkItem(at: hard, to: hard2)
        let scan = DiskScanner.scan(scope, cancellation: DiskCancellation(), activeBundleIDs: ["com.test.active"])
        if scan.files.map({ $0.url.path }) != [old.path] { print("Unexpected scan fixture paths: \(scan.files.map { $0.url.path })") }
        check(scan.files.map { $0.url.path } == [old.path], "scan excludes recent, active, package, hidden, symlink, hardlinks")
        check(scan.errors.isEmpty && !scan.limited && !scan.cancelled, "complete scan state")
        check(scan.files.first?.allocated == UInt64((try diskStat(old)).st_blocks) * 512, "allocated blocks differ from logical length")
        let token = DiskCancellation(); token.cancel()
        let cancelled = DiskScanner.scan(scope, cancellation: token)
        check(cancelled.cancelled && cancelled.files.isEmpty, "pre-cancel scan returns no candidates")
        check(DiskScanner.scan(scope, cancellation: DiskCancellation(), limit: 1).limited, "traversal limit reported")
        let original = try candidate(old, scope)
        check(rejects { try candidate(linked, scope).validate() }, "symlink cannot be trashed")
        check(rejects { try candidate(hard, scope).validate() }, "hardlink cannot be trashed")
        check(rejects { try candidate(fresh, scope).validate() }, "recent cache cannot be trashed")
        check(rejects { try candidate(package, scope).validate() }, "package ancestor cannot be trashed")
        try make(old, data: "changed after scan")
        var calls = 0
        let stale = DiskCleaner.trash([original], mover: { _ in calls += 1 })
        check(stale.moved.isEmpty && stale.errors.count == 1 && calls == 0, "changed file rejected before mover")
        let current = try candidate(old, scope)
        let failed = DiskCleaner.trash([current], mover: { _ in throw DiskError.message("simulated Trash permission failure") })
        check(failed.moved.isEmpty && failed.errors.count == 1 && fm.fileExists(atPath: old.path), "Trash failure preserves source; no delete fallback")
        calls = 0
        let duplicate = DiskCleaner.trash([current, current], mover: { _ in calls += 1 })
        check(duplicate.moved.count == 1 && calls == 1, "duplicate selected path processed once")
        let activeItem = try candidate(active, scope)
        let running = DiskCleaner.trash([activeItem], activeBundleIDs: ["com.test.active"], mover: { _ in calls += 1 })
        check(running.moved.isEmpty && running.errors.count == 1 && calls == 1, "recheck running cache app at cleanup")
        let tooMany = DiskCleaner.trash(Array(repeating: current, count: 1001), mover: { _ in calls += 1 })
        check(tooMany.moved.isEmpty && tooMany.errors.count == 1 && calls == 1, "oversized batch rejected")
        let nested = cache.appendingPathComponent("nested"), nestedFile = nested.appendingPathComponent("data.cache")
        try make(nestedFile); let nestedCandidate = try candidate(nestedFile, scope)
        let saved = cache.appendingPathComponent("saved"); try fm.moveItem(at: nested, to: saved)
        try fm.createSymbolicLink(at: nested, withDestinationURL: saved)
        check(rejects { try nestedCandidate.validate() }, "parent replaced with symlink rejected")
        check(rejects { _ = try DiskScope(root: nested, kind: .large, home: home) }, "symlink root rejected")
        let largeScope = try DiskScope(root: downloads, kind: .large, home: home)
        let big = downloads.appendingPathComponent("sparse-test.dat")
        try Data().write(to: big)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 100 * 1024 * 1024); try handle.close()
        try make(downloads.appendingPathComponent("small.txt"))
        let largeScan = DiskScanner.scan(largeScope, cancellation: DiskCancellation())
        check(largeScan.files.count == 1 && largeScan.files.first?.logical == 100 * 1024 * 1024, "large file threshold inclusive; small file retained")
        // Full-disk fixtures model a startup volume; no machine-wide traversal is run by tests.
        let volume = fixture.appendingPathComponent("volume")
        let fullHome = volume.appendingPathComponent("Users/test")
        let personalBig = fullHome.appendingPathComponent("Downloads/personal.bin")
        let protectedURLs = [volume.appendingPathComponent("System/Library/system.bin"),
            volume.appendingPathComponent("Applications/Fixture.app/Contents/app.bin"),
            volume.appendingPathComponent("Library/shared.bin"),
            volume.appendingPathComponent("Users/other/Downloads/other.bin"),
            fullHome.appendingPathComponent("Library/Application Support/private.bin"),
            fullHome.appendingPathComponent("Downloads/.hidden.bin")]
        func sparse(_ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            let h = try FileHandle(forWritingTo: url); try h.truncate(atOffset: 100 * 1024 * 1024); try h.close()
        }
        for u in [personalBig] + protectedURLs { try sparse(u) }
        for path in ["System/Volumes/Data/duplicate.bin", "Volumes/External/external.bin", "dev/device.bin", "Network/remote.bin", ".vol/virtual.bin"] {
            try sparse(volume.appendingPathComponent(path))
        }
        let alias = fullHome.appendingPathComponent("Downloads/link-to-system")
        try fm.createSymbolicLink(at: alias, withDestinationURL: volume.appendingPathComponent("System"))
        let hardOne = fullHome.appendingPathComponent("Downloads/hard-one.bin")
        let hardTwo = fullHome.appendingPathComponent("Downloads/hard-two.bin")
        try sparse(hardOne); try fm.linkItem(at: hardOne, to: hardTwo)
        let fullScope = try DiskScope.wholeDisk(root: volume, home: fullHome)
        let whole = DiskScanner.scan(fullScope, cancellation: DiskCancellation())
        check(fullScope.isWholeDisk && fullScope.kind == .large && whole.wholeDisk, "full-disk read scope is distinct from personal cleanup scope")
        check(diskContains("/Users/test", in: "/") && !diskContains("/", in: "/"), "whole-disk root handles path boundary")
        check(Set(whole.files.map { $0.url.path }).isSuperset(of: Set(([personalBig] + protectedURLs).map { $0.path })),
              "whole-disk scan includes personal, system, package, Library, other-user and hidden large files")
        check(whole.files.count == 8 && whole.excludedPaths.count == 5 && whole.errors.isEmpty,
              "auxiliary, external, virtual and duplicate volume entrances excluded; hardlinks counted once")
        check(whole.files.filter { $0.cleanupAllowed }.map { $0.url.path } == [personalBig.path], "only ordinary personal file eligible for cleanup in broad results")
        check(whole.statusTitle == "可访问范围扫描完成" && !whole.limited, "full-disk completion describes accessible scope")
        let largestOnly = DiskScanner.scan(fullScope, cancellation: DiskCancellation(), resultLimit: 2)
        check(largestOnly.matched == 8 && largestOnly.files.count == 2 && !largestOnly.limited && largestOnly.resultsCapped,
              "result display cap never stops full-disk traversal")
        check(largestOnly.files.map { $0.url.path } == Array(whole.files.prefix(2)).map { $0.url.path },
              "bounded full-disk results retain globally largest files with deterministic ties")
        check(largestOnly.statusTitle.contains("占用最大的部分"), "display truncation is explicitly disclosed")
        check(!whole.files.contains { $0.url.path.contains("link-to-system") }, "full-disk scan never follows symlink directories")
        var fullMoves: [String] = []
        let protectedOutcome = DiskCleaner.trashSelection(whole.files, mover: { fullMoves.append($0.path) })
        check(fullMoves == [personalBig.path] && protectedOutcome.errors.count == 7, "cleanup independently refuses protected full-disk candidates")
        check(DiskScanner.scan(fullScope, cancellation: token).cancelled, "whole-disk pre-cancellation is honored")
        check(DiskScanner.scan(fullScope, cancellation: DiskCancellation(), limit: 2).limited, "whole-disk traversal cap is explicitly partial")
        check(DiskScanner.scan(fullScope, cancellation: DiskCancellation(), seconds: 0).limited, "whole-disk time cap is explicitly partial")
        let deniedFull = volume.appendingPathComponent("Denied")
        try fm.createDirectory(at: deniedFull, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedFull.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedFull.path) }
        let partialFull = DiskScanner.scan(fullScope, cancellation: DiskCancellation())
        check(partialFull.files.count == 8 && partialFull.hasPermissionError && partialFull.rootFailure == nil,
              "whole-disk permission error preserves accessible files and incomplete status")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedFull.path)
        let fullRoot = try DiskScope.wholeDisk(root: deniedFull, home: fullHome)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedFull.path)
        let deniedFullRoot = DiskScanner.scan(fullRoot, cancellation: DiskCancellation())
        check(deniedFullRoot.rootFailure != nil && deniedFullRoot.hasPermissionError, "whole-disk unreadable root is not reported as empty success")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedFull.path)
        check(rejects { _ = try DiskScope.wholeDisk(root: alias, home: fullHome) }, "whole-disk entry cannot be a symlink")
        // Revalidate identity and ancestors even when a full-disk result was previously selectable.
        if let originalFull = whole.files.first(where: { $0.url.path == personalBig.path }) {
            try Data("changed after scan".utf8).write(to: personalBig)
            check(rejects { try originalFull.validate() }, "full-disk cleanup rejects changed personal file")
        } else { check(false, "full-disk personal fixture present") }
        let logScope = try DiskScope(root: logs, kind: .logs, home: home)
        try make(logs.appendingPathComponent("old.log"), days: 31); try make(logs.appendingPathComponent("new.log"), days: 29)
        check(DiskScanner.scan(logScope, cancellation: DiskCancellation()).files.count == 1, "logs use 30-day cutoff")
        let missing = try DiskScope(root: home.appendingPathComponent("Missing"), kind: .large, home: home)
        check(!DiskScanner.scan(missing, cancellation: DiskCancellation()).errors.isEmpty, "missing directory reports error")
        check(!DiskScanResult.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), "missing path is not misclassified as permission denial")
        for error in [NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                      NSError(domain: "wrapped-test", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])] {
            check(DiskScanResult.isPermissionError(error), "recognize permission error \(error.domain)/\(error.code)")
        }
        let blocked = home.appendingPathComponent("PermissionFixture")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedScope = try DiskScope(root: blocked, kind: .large, home: home)
        let inaccessible = blocked.appendingPathComponent("large-test.dat")
        try Data().write(to: inaccessible)
        let blockedHandle = try FileHandle(forWritingTo: inaccessible)
        try blockedHandle.truncate(atOffset: 100 * 1024 * 1024); try blockedHandle.close()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let denied = DiskScanner.scan(blockedScope, cancellation: DiskCancellation())
        check(denied.hasPermissionError && denied.rootFailure != nil && denied.files.isEmpty && denied.statusTitle == "需要文件夹访问权限", "real denied root returns explicit permission state")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        let recovered = DiskScanner.scan(blockedScope, cancellation: DiskCancellation())
        check(recovered.files.count == 1 && !recovered.hasPermissionError && recovered.statusTitle == "扫描完成", "retry after restoring access returns real large-file result")
        let child = blocked.appendingPathComponent("DeniedChild")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: child.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path) }
        let partialAccess = DiskScanner.scan(blockedScope, cancellation: DiskCancellation())
        check(partialAccess.files.count == 1 && partialAccess.hasPermissionError && partialAccess.rootFailure == nil,
              "denied child preserves readable results and does not mark entire root unavailable")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let emptyScope = try DiskScope(root: child, kind: .large, home: home)
        check(DiskScanner.scan(emptyScope, cancellation: DiskCancellation()).statusTitle == "扫描完成", "readable empty folder remains successful")
        let partial = DiskCleaner.trash([original, current], mover: { _ in calls += 1 })
        // Same path is intentionally deduplicated even when first attempt was stale.
        check(partial.moved.isEmpty && partial.errors.count == 1, "stale duplicate never silently retried")
        let mixed = DiskCleaner.trash([original, activeItem], mover: { _ in calls += 1 })
        check(mixed.moved.count == 1 && mixed.errors.count == 1, "one stale file does not stop independent valid item")
        var batchFiles: [DiskCandidate] = []
        for index in 0..<1001 {
            let url = cache.appendingPathComponent("batch-test-\(index).cache")
            try make(url); batchFiles.append(try candidate(url, scope))
        }
        var movedPaths: [String] = []
        let fullSelection = DiskCleaner.trashSelection(batchFiles + [batchFiles[0], original], mover: { movedPaths.append($0.path) })
        if fullSelection.moved.count != 1001 || fullSelection.errors.count != 1 {
            print("Batch fixture detail: moved=\(fullSelection.moved.count) errors=\(fullSelection.errors.count)\n\(fullSelection.errors.prefix(5).joined(separator: "\n"))")
        }
        check(fullSelection.moved.count == 1001 && Set(movedPaths).count == 1001 && movedPaths.count == 1001,
              "all 1001 selected files processed across batches without duplicate moves")
        check(fullSelection.errors.count == 1, "batch selection preserves per-file validation errors")
        let rejectedSelection = DiskCleaner.trashSelection(Array(repeating: current, count: 10001), mover: { _ in calls += 1 })
        check(rejectedSelection.moved.isEmpty && rejectedSelection.errors.count == 1, "selection remains bounded by scan result limit")
        check(DiskCapacity.read(at: home).map { $0.total > 0 && $0.free <= $0.total } == true, "live volume capacity sane")
        // Real system Trash integration uses ONLY this fresh, identifiable fixture and restores it.
        let real = logs.appendingPathComponent("MacPulse-trash-test-" + UUID().uuidString + ".txt")
        let marker = "MacPulse uniquely owned Trash integration fixture " + UUID().uuidString
        try make(real, data: marker)
        let realItem = try candidate(real, logScope)
        var trashed: NSURL?
        let realResult = DiskCleaner.trash([realItem], mover: { url in try fm.trashItem(at: url, resultingItemURL: &trashed) })
        let trashURL = trashed as URL?
        check(realResult.moved.count == 1 && !fm.fileExists(atPath: real.path) && trashURL != nil, "real Trash moved test-owned file")
        if let t = trashURL {
            guard try String(contentsOf: t, encoding: .utf8) == marker else { throw DiskError.message("Unexpected fixture contents; do not touch Trash item") }
            try fm.moveItem(at: t, to: real)
            check(try String(contentsOf: real, encoding: .utf8) == marker, "test-owned trashed file restored intact")
        } else { check(false, "Trash restoration URL available") }
    } catch { check(false, "fixture operation: \(error.localizedDescription)") }
    print("Disk: \(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}

// Exercise actual module views and the asynchronous scanner with isolated sample files.
func diskUISelfTest() {
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("MacPulseUIFixture-" + UUID().uuidString)
    do {
        let home = fixture.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let large = downloads.appendingPathComponent("Permission-retry-large.dat")
        try Data().write(to: large)
        let largeHandle = try FileHandle(forWritingTo: large); try largeHandle.truncate(atOffset: 100 * 1024 * 1024); try largeHandle.close()
        for name in ["Preview-old-cache.dat", "Preview-other-cache.dat"] {
            let url = caches.appendingPathComponent(name)
            try Data(repeating: 65, count: 8192).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: url.path)
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); delegate.diskTool = DiskTool(home: home, wholeDiskRoot: fixture); app.delegate = delegate
        let tool = delegate.diskTool
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") UI: \(name)"); fflush(stdout)
        }
        func finish() {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloads.path)
            do { try fm.removeItem(at: fixture) } catch { check(false, "test-owned UI fixture cleanup") }
            print("UI: \(checks - failures)/\(checks) checks passed"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let began = Date()
        func waitForScan(_ completion: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !tool.busy { completion() }
                else if Date().timeIntervalSince(began) > 10 { check(false, "asynchronous scan completed within deadline"); finish() }
                else { waitForScan(completion) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            check(delegate.window.title.contains("1.4.0"), "visible version identifies correct artifact")
            check(!delegate.diagnosticsView.isHidden && tool.view.isHidden, "diagnostics remains default module")
            delegate.modules.selectedSegment = 1; delegate.switchModule()
            check(delegate.diagnosticsView.isHidden && !tool.view.isHidden, "disk module switch")
            check(tool.selected.isEmpty && !tool.cleanButton.isEnabled, "initial cleanup disabled")
            check(!tool.selectionHeader.selectAll.isEnabled && tool.selectionHeader.selectAll.state == .off, "empty list header disabled and unchecked")
            check(tool.selectionHeader.accessibilityChildren()?.contains { ($0 as? NSView) === tool.selectionHeader.selectAll } == true, "select-all header exposed to accessibility")
            tool.scan()
            check(tool.busy && !tool.category.isEnabled && tool.cancelButton.isEnabled, "scanning locks category but permits cancellation")
            check(!tool.selectionHeader.selectAll.isEnabled, "scan disables select-all header")
            tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
            check(tool.category.selectedSegment == DiskKind.caches.rawValue, "busy scan rejects category switch without changing its result destination")
            waitForScan {
                check(tool.files.count == 2 && tool.table.numberOfRows == 2, "background scan populates actual file table")
                check(tool.selected.isEmpty && !tool.cleanButton.isEnabled, "scan never preselects candidates")
                tool.selectionHeader.selectAll.performClick(nil)
                check(tool.selected.count == 2 && tool.cleanButton.isEnabled, "explicit selection enables cleanup")
                check(tool.selectionHeader.selectAll.state == .on, "header click selects entire list and shows checked state")
                let row = NSButton(checkboxWithTitle: "", target: nil, action: nil); row.tag = 0
                tool.toggleFile(row)
                check(tool.selected.count == 1 && tool.selectionHeader.selectAll.state == .mixed, "unchecking one row produces mixed header state")
                tool.selectionHeader.selectAll.performClick(nil)
                check(tool.selected.count == 2 && tool.selectionHeader.selectAll.state == .on, "mixed header click completes full selection")
                tool.selectResults()
                check(tool.selected.isEmpty && !tool.cleanButton.isEnabled, "clear selection disables cleanup")
                check(tool.selectionHeader.selectAll.state == .off, "bottom button and header stay synchronized")
                let originalFiles = tool.files
                if let sample = originalFiles.first {
                    tool.files = (0..<1001).map { DiskCandidate(url: sample.scope.root.appendingPathComponent("selection-\($0).cache"), scope: sample.scope, identity: sample.identity) }
                    tool.table.reloadData(); tool.updateSelection(); tool.selectionHeader.selectAll.performClick(nil)
                    check(tool.selected.count == 1001 && tool.selectionHeader.selectAll.state == .on, "select-all includes results beyond former 1000-file cap")
                    tool.selectionHeader.selectAll.performClick(nil)
                    check(tool.selected.isEmpty && tool.selectionHeader.selectAll.state == .off, "second header click clears full selection")
                    delegate.window.contentView?.layoutSubtreeIfNeeded()
                    if let scroll = tool.table.enclosingScrollView {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: 480)); scroll.reflectScrolledClipView(scroll.contentView)
                        let previousY = scroll.contentView.bounds.origin.y
                        tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
                        tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                        check(previousY > 0 && abs(scroll.contentView.bounds.origin.y - previousY) < 1, "tab switch restores file-list scroll position")
                    } else { check(false, "file list has a scroll view") }
                    tool.files = originalFiles; tool.table.reloadData(); tool.updateSelection()
                } else { check(false, "fixture scan supplied selection samples") }
                tool.toggleFile(row)
                tool.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let cachedPaths = tool.files.map { $0.url.path }
                let cachedSelection = tool.selected
                let cachedSummary = tool.found.stringValue
                let cachedReport = tool.report
                tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
                check(tool.files.isEmpty && tool.selected.isEmpty && !tool.cleanButton.isEnabled, "unscanned tab starts empty without another tab's selection")
                tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                check(tool.files.map { $0.url.path } == cachedPaths && tool.files.count == 2, "switching back restores earlier cache scan without rescanning")
                check(tool.selected == cachedSelection && tool.selectionHeader.selectAll.state == .mixed, "switching back restores per-tab checkbox selection")
                check(tool.found.stringValue == cachedSummary && tool.report == cachedReport, "tab switch preserves summary and report")
                check(tool.table.selectedRow == 0 && tool.detail.stringValue == cachedPaths.first, "tab switch restores selected file detail")
                delegate.modules.selectedSegment = 0; delegate.switchModule()
                delegate.modules.selectedSegment = 1; delegate.switchModule()
                check(tool.files.map { $0.url.path } == cachedPaths && tool.selected == cachedSelection, "top-level module switch also preserves disk state")
                tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
                tool.scan()
                waitForScan {
                    check(tool.report.contains("日志") && tool.status.stringValue.contains("无法读取扫描目录"), "missing log directory visible as root read failure")
                    tool.category.selectedSegment = DiskKind.large.rawValue; tool.changeCategory()
                    check(!tool.folderButton.isHidden && !tool.wholeDiskButton.isHidden && tool.largeUsesWholeDisk && tool.rootURL == fixture,
                          "large-file tab defaults to full startup-disk scan and retains folder picker")
                    check(tool.scanButton.title == "开始全盘扫描" && tool.folderLabel.stringValue.contains("启动磁盘"), "full-disk action explicitly says start full-disk scan")
                    check(tool.wholeDiskButton.title == "已选：全盘" && !tool.wholeDiskButton.isEnabled &&
                          tool.status.stringValue.contains("点击右侧"), "selected range is visibly distinct from the enabled start action")
                    tool.wholeDiskButton.performClick(nil)
                    check(!tool.busy && tool.found.stringValue == "尚未扫描", "selected range cannot masquerade as a scan action")
                    tool.scanButton.performClick(nil)
                    check(tool.found.stringValue == "扫描中…" && tool.status.stringValue.contains("正在扫描启动磁盘"), "clicking the actual full-disk start action immediately confirms scanning")
                    check(tool.busy && !tool.wholeDiskButton.isEnabled && !tool.folderButton.isEnabled, "scan locks full-disk and folder mode changes")
                    waitForScan {
                    check(tool.files.count == 1 && tool.files.first?.scope.isWholeDisk == true && tool.permissionPanel.isHidden, "full-disk UI scans injected volume rather than only Downloads")
                    tool.selectResults()
                    let fullPaths = tool.files.map { $0.url.path }
                    let fullReport = tool.report
                    tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                    tool.category.selectedSegment = DiskKind.large.rawValue; tool.changeCategory()
                    check(tool.files.map { $0.url.path } == fullPaths && tool.selected.count == 1 && tool.report == fullReport,
                          "full-disk results and selection survive category switching")
                    // Insert a system-path fixture candidate to exercise read-only UI without accessing user files.
                    if let sample = tool.files.first {
                        let system = DiskCandidate(url: fixture.appendingPathComponent("System/protected.bin"), scope: sample.scope, identity: sample.identity)
                        tool.files.append(system); tool.table.reloadData(); tool.updateSelection(); tool.selectResults(); tool.selectResults()
                        check(tool.selected.count == 1 && !tool.selected.contains(system.url.path), "select-all excludes protected full-disk files")
                        let column = tool.table.tableColumns[0]
                        let button = tool.tableView(tool.table, viewFor: column, row: 1) as? NSButton
                        check(button?.isEnabled == false && button?.title == "仅查看", "protected result checkbox is disabled and labeled read-only")
                        delegate.window.contentView?.layoutSubtreeIfNeeded()
                        check(tool.scanButton.frame.minX >= tool.cancelButton.frame.maxX &&
                              tool.wholeDiskButton.frame.width >= tool.wholeDiskButton.fittingSize.width - 1,
                              "full-disk controls fit the native window without overlap or clipped mode title")
                        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--disk-ui-preview=") }) {
                            do { try delegate.renderPreview(to: String(argument.dropFirst(18))) }
                            catch { check(false, "render native full-disk preview") }
                        }
                        let protectedButton = NSButton(); protectedButton.tag = 1; tool.toggleFile(protectedButton)
                        check(!tool.selected.contains(system.url.path), "direct row action cannot select protected candidate")
                        tool.files.removeLast(); tool.table.reloadData(); tool.updateSelection()
                    } else { check(false, "full-disk fixture available for protected-row checks") }
                    do { try tool.useLargeFolder(downloads) }
                    catch { check(false, "select isolated large-file fixture"); finish(); return }
                    do { try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: downloads.path) }
                    catch { check(false, "create test-only denied folder"); finish(); return }
                    tool.scan()
                    waitForScan {
                        check(tool.found.stringValue == "需要文件夹访问权限" && !tool.permissionPanel.isHidden, "denied scan shows permission recovery panel instead of zero-size success")
                        check(!tool.busy && tool.scanButton.isEnabled && tool.scanButton.title == "重试扫描", "denied scan settles with enabled retry")
                        check(tool.permissionSettingsButton.isEnabled && !tool.permissionFolderButton.isHidden && tool.permissionFolderButton.isEnabled, "settings and folder recovery actions available")
                        check(tool.files.isEmpty && tool.selected.isEmpty && !tool.cleanButton.isEnabled, "denied scan cannot clean stale or unscanned files")
                        tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                        check(tool.files.map { $0.url.path } == cachedPaths && tool.selected == cachedSelection, "another tab's permission failure leaves cached results untouched")
                        tool.category.selectedSegment = DiskKind.large.rawValue; tool.changeCategory()
                        check(tool.found.stringValue == "需要文件夹访问权限" && !tool.permissionPanel.isHidden && tool.scanButton.title == "重试扫描", "tab switch restores permission failure and recovery actions")
                        do { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloads.path) }
                        catch { check(false, "restore test-only folder permission"); finish(); return }
                        tool.scan()
                        waitForScan {
                            check(tool.files.count == 1 && tool.permissionPanel.isHidden && tool.scanButton.title == "开始扫描", "same app recovers by retry after access is restored")
                            check(tool.selected.isEmpty && !tool.cleanButton.isEnabled, "recovered scan still does not preselect")
                            tool.selectionHeader.selectAll.performClick(nil)
                            let largePaths = tool.files.map { $0.url.path }
                            tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
                            check(tool.report.contains("日志") && tool.status.stringValue.contains("无法读取扫描目录") && tool.permissionPanel.isHidden,
                                  "each tab retains its own report and error type")
                            tool.category.selectedSegment = DiskKind.large.rawValue; tool.changeCategory()
                            check(tool.files.map { $0.url.path } == largePaths && tool.selected.count == 1 && tool.selectionHeader.selectAll.state == .on,
                                  "large-file results and full selection survive switching tabs")
                            let otherFolder = downloads.appendingPathComponent("OtherFolder")
                            do { try fm.createDirectory(at: otherFolder, withIntermediateDirectories: true); try tool.useLargeFolder(otherFolder) }
                            catch { check(false, "accept explicitly selected personal directory"); finish(); return }
                            check(tool.files.isEmpty && tool.selected.isEmpty && tool.largeFolder == otherFolder, "changing folder clears old results before new scan")
                            check(tool.wholeDiskButton.isEnabled && tool.wholeDiskButton.title == "切换到全盘", "folder mode offers clearly named range switch")
                            tool.useWholeDisk()
                            check(tool.files.map { $0.url.path } == fullPaths && tool.selected.count == 1 && tool.largeUsesWholeDisk && tool.report == fullReport,
                                  "returning to full-disk mode restores its independent cached scan")
                            do { try tool.useLargeFolder(otherFolder) }
                            catch { check(false, "return to selected test folder"); finish(); return }
                            tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                            check(tool.files.map { $0.url.path } == cachedPaths && tool.selected == cachedSelection, "changing large-file directory does not invalidate cache tab")
                            // Simulate a completed test-owned cleanup; actual Trash movement is covered separately.
                            if let removed = tool.files.first {
                                tool.applyTrashResult(DiskTrashResult(moved: [removed]))
                                tool.category.selectedSegment = DiskKind.logs.rawValue; tool.changeCategory()
                                tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                                check(tool.files.count == 1 && !tool.files.contains { $0.url.path == removed.url.path } && tool.selected.isEmpty,
                                      "switching tabs never resurrects items removed by cleanup")
                            } else { check(false, "cache result available for cleanup-state regression") }
                            tool.category.selectedSegment = DiskKind.large.rawValue; tool.changeCategory()
                            check(tool.files.isEmpty && tool.largeFolder == otherFolder, "invalidated large-file result stays empty after a round trip")
                            tool.category.selectedSegment = DiskKind.caches.rawValue; tool.changeCategory()
                            tool.scan()
                            check(tool.files.isEmpty && tool.selected.isEmpty && !tool.cleanButton.isEnabled, "rescan invalidates only its current result and selection")
                            waitForScan {
                            check(tool.files.count == 2 && tool.selected.isEmpty, "rescan replaces cached snapshot with new filesystem results")
                            tool.scan(); tool.cancel()
                            waitForScan {
                                check(tool.cancellation == nil && !tool.cancelButton.isEnabled && !tool.busy, "cancel request settles and unlocks controls")
                                check(tool.selected.isEmpty && !tool.cleanButton.isEnabled, "cancelled scan never selects files")
                                delegate.modules.selectedSegment = 0; delegate.switchModule()
                                check(!delegate.diagnosticsView.isHidden && tool.view.isHidden, "return to original diagnostics module")
                                do {
                                    let probe = DiskTool(home: home, wholeDiskRoot: fixture)
                                    probe.category.selectedSegment = DiskKind.large.rawValue; probe.changeCategory()
                                    let fullScope = try DiskScope.wholeDisk(root: fixture, home: home)
                                    let file = DiskCandidate(url: large, scope: fullScope, identity: try diskStat(large))
                                    probe.receive(DiskScanResult(files: [file], wholeDisk: true), scope: fullScope)
                                    try probe.useLargeFolder(downloads)
                                    let folderScope = try DiskScope(root: downloads, kind: .large, home: home)
                                    probe.receive(DiskScanResult(files: [DiskCandidate(url: large, scope: folderScope, identity: try diskStat(large))]), scope: folderScope)
                                    probe.applyTrashResult(DiskTrashResult(moved: [file]))
                                    probe.useWholeDisk()
                                    check(probe.files.isEmpty && probe.found.stringValue.contains("剩余 0"), "cleanup in folder mode also removes overlapping cached full-disk result")
                                    check(probe.selected.isEmpty && !probe.cleanButton.isEnabled, "synchronized cleanup cannot restore stale selections")
                                } catch { check(false, "cross-scope cleanup fixture") }
                                finish()
                            }
                            }
                        }
                    }
                    }
                }
            }
        }
        app.run()
    } catch { try? fm.removeItem(at: fixture); print("FAIL UI fixture: \(error.localizedDescription)"); exit(1) }
}
