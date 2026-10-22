import AppKit

func uninstallSelfTest() {
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("MacPulseUninstall-" + UUID().uuidString)
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") uninstall: \(name)") }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    do {
        let home = fixture.appendingPathComponent("home"), apps = fixture.appendingPathComponent("Applications")
        for url in [home, apps] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: fixture) }
        func write(_ url: URL, _ value: String = "test-owned uninstall sample") throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        func app(_ name: String, _ id: String, root: URL? = nil) throws -> URL {
            let url = (root ?? apps).appendingPathComponent(name + ".app")
            let info = url.appendingPathComponent("Contents/Info.plist")
            let dictionary: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
            try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: info)
            try write(url.appendingPathComponent("Contents/MacOS/Fixture"))
            return url
        }
        let environment = UninstallEnvironment(home: home, applicationRoots: [apps], resolveApplication: { _ in nil }, isRunning: { _, _ in false })
        let id = "com.example.uninstallfixture"
        let appURL = try app("Sample Editor", id), record = try UninstallApplication.read(appURL, environment: environment)
        let target = UninstallTarget(application: record)
        let cache = UninstallKind.cache.path(for: id, home: home)!, prefs = UninstallKind.preferences.path(for: id, home: home)!
        let support = UninstallKind.support.path(for: id, home: home)!
        try write(cache.appendingPathComponent("old.cache")); try write(prefs); try write(support.appendingPathComponent("database.db"))
        let similar = home.appendingPathComponent("Library/Application Support/Sample Editor")
        try write(similar.appendingPathComponent("user-document.txt"))
        let container = UninstallKind.container.path(for: id, home: home)!
        try write(container.appendingPathComponent("Data/Documents/important.txt"))
        let agent = UninstallKind.agent.path(for: id, home: home)!; try write(agent)
        let shared = home.appendingPathComponent("Library/Group Containers/\(id)"); try write(shared.appendingPathComponent("shared.txt"))
        let sibling = home.appendingPathComponent("Library/Caches/\(id).helper"); try write(sibling.appendingPathComponent("helper.cache"))
        let catalog = UninstallCatalog.read(environment)
        check(catalog.complete && catalog.applications.count == 1 && catalog.applications.first?.identifier == id, "catalog reads application metadata in approved roots")
        check(!UninstallPolicy.validIdentifier("../Library") && !UninstallPolicy.validIdentifier("com..bad") &&
              UninstallPolicy.validIdentifier(id), "identifier grammar rejects traversal and empty components")
        check(rejects { _ = try UninstallApplication.read(appURL, environment: UninstallEnvironment(home: home, applicationRoots: [])) },
              "application outside approved roots rejected")
        let nested = try app("Helper", "com.example.helper", root: appURL.appendingPathComponent("Contents"))
        check(rejects { _ = try UninstallApplication.read(nested, environment: environment) }, "cannot uninstall embedded helper as standalone app")
        let scan = UninstallScanner.scan(target, environment: environment, cancellation: DiskCancellation())
        check(scan.protection == nil && scan.items.filter(\.selectable).count == 4, "only app and exact-ID cache, preferences and application data selectable")
        check(scan.items.contains { $0.url.path == support.path && $0.kind == .support && $0.kind.title.contains("需备份") }, "application support data explicitly labeled backup-sensitive")
        check(scan.items.filter { $0.kind == .nameMatch || $0.kind == .container || $0.kind == .agent }.allSatisfy { !$0.selectable } &&
              scan.items.contains { $0.url.path == similar.path }, "name-only, sandbox documents and background services remain view-only")
        check(!scan.items.contains { $0.url.path == shared.path || $0.url.path == sibling.path }, "shared containers and partial-ID sibling directories never included")
        var calls: [URL] = []
        let cacheOutcome = UninstallCleaner.trash(scan, selected: [cache.path], environment: environment, mover: { calls.append($0) })
        check(cacheOutcome.moved.map(\.path) == [cache.path] && calls.map(\.path) == [cache.path], "explicit single selection moves only exact approved path")
        let unknown = UninstallCleaner.trash(scan, selected: [shared.path], environment: environment, mover: { calls.append($0) })
        check(unknown.moved.isEmpty && !unknown.errors.isEmpty && calls.count == 1, "unknown shared path cannot reach mover")
        let protectedOutcome = UninstallCleaner.trash(scan, selected: [container.path], environment: environment, mover: { calls.append($0) })
        check(protectedOutcome.moved.isEmpty && !protectedOutcome.errors.isEmpty, "view-only candidate rejected by cleanup backend")
        let fakeItem = UninstallItem(url: shared, kind: .cache, tree: UninstallTree.read(shared, cancellation: DiskCancellation()), protectedReason: nil)
        let fakeReport = UninstallReport(target: target, items: [fakeItem])
        check(UninstallCleaner.trash(fakeReport, selected: [shared.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "forged candidate cannot escape recomputed exact-ID whitelist")
        if let item = scan.items.first(where: { $0.url.path == cache.path }) {
            let duplicate = UninstallReport(target: target, items: [item, item])
            check(UninstallCleaner.trash(duplicate, selected: [cache.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
                  "duplicated report rows cannot move the same path twice")
        } else { check(false, "cache fixture exists") }
        try write(cache.appendingPathComponent("new-after-scan.cache"))
        let stale = UninstallCleaner.trash(scan, selected: [cache.path], environment: environment, mover: { calls.append($0) })
        check(stale.moved.isEmpty && !stale.errors.isEmpty && calls.count == 1, "nested tree mutation invalidates old cleanup evidence")
        let fresh = UninstallScanner.scan(target, environment: environment, cancellation: DiskCancellation())
        let failed = UninstallCleaner.trash(fresh, selected: [cache.path], environment: environment, mover: { _ in throw DiskError.message("test Trash denied") })
        check(failed.moved.isEmpty && fm.fileExists(atPath: cache.path), "Trash failure preserves folder without delete fallback")
        var running = environment; running.isRunning = { _, _ in true }
        let protectedScan = UninstallScanner.scan(target, environment: running, cancellation: DiskCancellation())
        check(protectedScan.protection != nil && protectedScan.items.allSatisfy { !$0.selectable }, "running app and all its data protected")
        check(UninstallCleaner.trash(fresh, selected: [cache.path], environment: running, mover: { calls.append($0) }).moved.isEmpty,
              "app restarting after inspection blocks cleanup")
        let token = DiskCancellation(); token.cancel()
        let cancelled = UninstallScanner.scan(target, environment: environment, cancellation: token)
        check(cancelled.cancelled && UninstallCleaner.trash(cancelled, selected: [cache.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "cancelled report cannot authorize cleanup")
        let limited = UninstallScanner.scan(target, environment: environment, cancellation: DiskCancellation(), treeLimit: 1)
        check(limited.items.first(where: { $0.kind == .application })?.selectable == false, "partial tree statistics cannot authorize bundle removal")
        check(!UninstallTree.read(appURL, cancellation: token).complete, "pre-cancelled tree fingerprint stays incomplete")
        let otherApp = try app("Second Copy", id)
        let two = UninstallScanner.scan(target, environment: environment, cancellation: DiskCancellation())
        check(two.items.first(where: { $0.kind == .application })?.selectable == true &&
              two.items.filter { $0.kind != .application }.allSatisfy { !$0.selectable }, "second installed copy preserves shared settings while allowing selected app body")
        check(UninstallCleaner.trash(fresh, selected: [prefs.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "newly installed second copy blocks old associated-data selection")
        try fm.removeItem(at: otherApp)
        let apple = try app("Protected System", "com.apple.fixture")
        let own = try app("MacPulse Copy", productID)
        for url in [apple, own] {
            let protectedTarget = UninstallTarget(application: try UninstallApplication.read(url, environment: environment))
            check(UninstallScanner.scan(protectedTarget, environment: environment, cancellation: DiskCancellation()).protection != nil,
                  "Apple and own bundle identifiers protected")
        }
        let orphanID = "com.example.removedfixture", orphanCache = UninstallKind.cache.path(for: "com.example.removedfixture", home: home)!
        try write(orphanCache.appendingPathComponent("leftover.cache"))
        let residues = UninstallScanner.residues(environment, cancellation: DiskCancellation())
        check(residues.targets.contains { $0.identifier == orphanID } && !residues.targets.contains { $0.identifier == id || $0.identifier.hasPrefix("com.apple.") },
              "residue discovery distinguishes missing identifiers from installed and Apple apps")
        check(!residues.targets.contains { $0.identifier == id + ".helper" },
              "helper identifier of installed app is not misclassified as orphan data")
        let helperReport = UninstallScanner.scan(UninstallTarget(identifier: id + ".helper"), environment: environment, cancellation: DiskCancellation())
        check(helperReport.protection != nil, "backend also protects related installed helper identifiers")
        let orphanTarget = UninstallTarget(identifier: orphanID)
        let orphanReport = UninstallScanner.scan(orphanTarget, environment: environment, cancellation: DiskCancellation())
        check(orphanReport.protection == nil && orphanReport.items.first?.selectable == true && orphanReport.text.contains("不等于"),
              "orphan candidate remains explicitly uncertain and needs user confirmation")
        check(UninstallCleaner.trash(orphanReport, selected: [orphanCache.path], environment: environment, mover: { calls.append($0) }).moved.map(\.path) == [orphanCache.path],
              "confirmed orphan exact-ID path can be moved")
        let resurrected = try app("Reinstalled", orphanID)
        check(UninstallCleaner.trash(orphanReport, selected: [orphanCache.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "reinstallation after residue scan prevents cleanup")
        try fm.removeItem(at: resurrected)
        let external = fixture.appendingPathComponent("Elsewhere.app"); try fm.createDirectory(at: external, withIntermediateDirectories: true)
        var registered = environment; registered.resolveApplication = { $0 == orphanID ? external : nil }
        check(UninstallScanner.scan(orphanTarget, environment: registered, cancellation: DiskCancellation()).protection != nil,
              "registered app outside standard directories prevents orphan cleanup")
        let saved = home.appendingPathComponent("SavedCache"); try fm.moveItem(at: cache, to: saved)
        try fm.createSymbolicLink(at: cache, withDestinationURL: shared)
        check(UninstallCleaner.trash(fresh, selected: [cache.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "candidate replaced by symlink rejected")
        try fm.removeItem(at: cache); try fm.moveItem(at: saved, to: cache)
        let denied = cache.appendingPathComponent("Denied"); try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        let inaccessible = UninstallScanner.scan(target, environment: environment, cancellation: DiskCancellation())
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        check(inaccessible.items.first(where: { $0.url.path == cache.path })?.selectable == false, "permission-denied descendants block whole directory cleanup")
        let invalid = apps.appendingPathComponent("Invalid.app"); try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        check(!UninstallCatalog.read(environment).complete &&
              UninstallScanner.scan(orphanTarget, environment: environment, cancellation: DiskCancellation()).protection != nil,
              "incomplete application catalog cannot establish removable orphan data")
        try fm.removeItem(at: invalid)
        var info = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")); info.append(Data("\n".utf8))
        try info.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        check(UninstallCleaner.trash(fresh, selected: [appURL.path], environment: environment, mover: { calls.append($0) }).moved.isEmpty,
              "application update or identity metadata change rejects stale selection")
        let currentTarget = UninstallTarget(application: try UninstallApplication.read(appURL, environment: environment))
        let current = UninstallScanner.scan(currentTarget, environment: environment, cancellation: DiskCancellation())
        var trashURL: NSURL?
        let moved = UninstallCleaner.trash(current, selected: [appURL.path], environment: environment, mover: {
            try fm.trashItem(at: $0, resultingItemURL: &trashURL)
        })
        check(moved.moved == [appURL] && !fm.fileExists(atPath: appURL.path) && fm.fileExists(atPath: prefs.path),
              "real Trash moves only test-owned selected app and keeps unselected settings")
        if let url = trashURL as URL? {
            guard fm.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) else { throw DiskError.message("Unexpected Trash fixture") }
            try fm.moveItem(at: url, to: appURL)
            check(fm.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/Fixture").path), "test-owned application restored intact from Trash")
        } else { check(false, "app Trash restoration URL available") }
    } catch { check(false, "fixture operation: \(error.localizedDescription)") }
    print("Uninstall: \(checks - failures)/\(checks) checks passed"); exit(failures == 0 ? 0 : 1)
}

func uninstallUISelfTest() {
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("MacPulseUninstallUI-" + UUID().uuidString)
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") uninstall UI: \(name)"); fflush(stdout) }
    func finish() { try? fm.removeItem(at: fixture); print("Uninstall UI: \(checks - failures)/\(checks) checks passed"); fflush(stdout); exit(failures == 0 ? 0 : 1) }
    do {
        let home = fixture.appendingPathComponent("home"), apps = fixture.appendingPathComponent("Applications"), id = "com.example.editorfixture"
        let appURL = apps.appendingPathComponent("Sample Editor.app")
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "Sample Editor", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: info)
        for directory in ["Caches/\(id)", "Application Support/Sample Editor", "Containers/\(id)", "Caches/com.example.removedfixture"] {
            let root = home.appendingPathComponent("Library/\(directory)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true); try Data("test-owned sample".utf8).write(to: root.appendingPathComponent("sample.dat"))
        }
        let environment = UninstallEnvironment(home: home, applicationRoots: [apps], resolveApplication: { _ in nil }, isRunning: { _, _ in false })
        let app = NSApplication.shared; app.setActivationPolicy(.regular); let delegate = AppDelegate()
        delegate.uninstallTool = UninstallTool(environment: environment); app.delegate = delegate
        let tool = delegate.uninstallTool, deadline = ProcessInfo.processInfo.systemUptime + 20
        func wait(_ completion: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                if !tool.busy { completion() }
                else if ProcessInfo.processInfo.systemUptime > deadline { check(false, "uninstall background work completes"); finish() }
                else { wait(completion) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check(delegate.modules.segmentCount == 5 && delegate.window.title.contains("1.4.0"), "five modules and correct installed version")
            delegate.modules.selectedSegment = 4; delegate.switchModule()
            check(!tool.view.isHidden && delegate.diskTool.view.isHidden && delegate.networkTool.view.isHidden, "uninstall module visible independently")
            wait {
                check(tool.targets.count == 1 && tool.target?.identifier == id && !tool.cleanButton.isEnabled, "load installed app catalog without selecting removal")
                tool.inspectButton.performClick(nil)
                check(tool.busy && tool.cancelButton.isEnabled && !tool.mode.isEnabled, "inspection starts asynchronously with cancellation")
                wait {
                    check(tool.currentReport?.items.count == 4 && tool.selected.isEmpty && !tool.cleanButton.isEnabled, "app, cache and protected associations displayed without auto selection")
                    tool.selectApp()
                    check(tool.selected == [appURL.path], "app-only selection excludes user data")
                    tool.selectEligible()
                    check(tool.selected.count == 2 && tool.cleanButton.isEnabled, "select eligible skips sandbox and name-only associations")
                    if let index = tool.currentReport?.items.firstIndex(where: { $0.kind == .container }) {
                        let cell = tool.tableView(tool.table, viewFor: tool.table.tableColumns[0], row: index) as? NSButton
                        check(cell?.isEnabled == false && cell?.title == "仅查看", "protected data checkbox visibly disabled")
                        let attempt = NSButton(); attempt.tag = index; tool.toggle(attempt)
                        check(tool.selected.count == 2, "direct action cannot select protected sandbox data")
                    } else { check(false, "sandbox fixture visible") }
                    let paths = tool.selected
                    delegate.modules.selectedSegment = 0; delegate.switchModule()
                    delegate.modules.selectedSegment = 4; delegate.switchModule()
                    check(tool.selected == paths && tool.currentReport?.items.count == 4, "module switch preserves uninstall report and selection")
                    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--uninstall-preview=") }) {
                        do { try delegate.renderPreview(to: String(arg.dropFirst(20))) } catch { check(false, "native uninstall preview") }
                    }
                    tool.clearSelection(); check(!tool.cleanButton.isEnabled, "clear selection disables destructive action")
                    tool.mode.selectedSegment = 1; tool.changeMode()
                    wait {
                        check(tool.targets.contains { $0.identifier == "com.example.removedfixture" } && !tool.targets.contains { $0.identifier == id },
                              "residue mode lists missing-app candidates and excludes installed app")
                        tool.inspect()
                        wait {
                            check(tool.currentReport?.target.orphan == true && tool.selected.isEmpty && tool.identityLabel.stringValue.contains("确认"),
                                  "orphan mode labels uncertainty and still starts unselected")
                            tool.selectEligible()
                            check(tool.selected.count == 1 && tool.cleanButton.isEnabled, "orphan selection remains explicit")
                            tool.applyTrashResult(UninstallTrashResult(moved: [home.appendingPathComponent("Library/Caches/com.example.removedfixture")]))
                            check(tool.currentReport == nil && tool.selected.isEmpty && !tool.cleanButton.isEnabled, "after cleanup old evidence is invalidated")
                            tool.mode.selectedSegment = 0; tool.changeMode()
                            wait {
                                tool.inspect(); tool.cancel()
                                wait {
                                    check(tool.currentReport?.cancelled == true && !tool.cleanButton.isEnabled && tool.inspectButton.isEnabled,
                                          "cancelled inspection settles and cannot authorize cleanup")
                                    finish()
                                }
                            }
                        }
                    }
                }
            }
        }
        app.run()
    } catch { check(false, error.localizedDescription); finish() }
}
