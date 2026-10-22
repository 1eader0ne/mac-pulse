import AppKit

final class HealthTestProtocol: URLProtocol {
    static let mode = HealthValue<Int>()
    static let lastRequest = HealthValue<URLRequest>()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest.set(request)
        let code = Self.mode.value ?? 200
        if code == 0 { return }
        if code < 0 { client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func toolboxSelfTest() {
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") tools: \(name)") }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("MacPulseTools-" + UUID().uuidString)
    do {
        let home = fixture.appendingPathComponent("home"), folder = home.appendingPathComponent("Documents")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let u = folder.appendingPathComponent(name); try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u); return u
        }
        let payload = Data("abc".utf8)
        let a = try write("a.txt", payload), b = try write("different-name.bin", payload), c = try write("third-copy.data", payload)
        _ = try write("same-size-different.txt", Data("abd".utf8))
        _ = try write("unique-size.txt", Data("unique byte count".utf8))
        _ = try write("empty.txt", Data())
        _ = try write(".hidden/copy.txt", payload)
        _ = try write("Fixture.app/Contents/copy.txt", payload)
        let hard = try write("hard-a", Data("hardlinked".utf8))
        try fm.linkItem(at: hard, to: folder.appendingPathComponent("hard-b"))
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked.txt"), withDestinationURL: a)
        let forked = try write("resource-fork.txt", payload)
        let forkData = Data("different resource-fork content".utf8)
        let forkOK = forkData.withUnsafeBytes { setxattr(forked.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        check(forkOK == 0, "test-owned resource fork created")
        let scope = try DiskScope(root: folder, kind: .large, home: home)
        let scan = DuplicateScanner.find(scope, cancellation: DiskCancellation())
        check(scan.groups.count == 1 && scan.groups[0].files.count == 3, "content-identical files found despite different names")
        check(Set(scan.groups.flatMap(\.files).map { $0.url.path }) == Set([a.path, b.path, c.path]), "same-size different bytes, hidden, package, link and resource-fork files excluded")
        check(scan.hashed == 4 && scan.bytesRead > 0 && scan.errors.isEmpty, "only repeated-size eligible files read and byte-verified")
        check(scan.groups.first?.digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known vector")
        check(scan.redundant.count == 2 && scan.groups.first?.files.first?.url == a, "deterministic first file retained in every group")
        let token = DiskCancellation(); token.cancel()
        check(DuplicateScanner.find(scope, cancellation: token).cancelled, "duplicate scan respects pre-cancellation")
        check(DuplicateScanner.find(scope, cancellation: DiskCancellation(), limit: 1).limited, "duplicate traversal cap explicitly partial")
        check(DuplicateScanner.find(scope, cancellation: DiskCancellation(), seconds: 0).limited, "duplicate time cap explicitly partial")
        check(DuplicateScanner.find(scope, cancellation: DiskCancellation(), byteLimit: 1).limited, "content I/O cap stops hashing rather than declaring unchecked duplicates")
        let whole = try DiskScope.wholeDisk(root: fixture, home: home)
        check(DuplicateScanner.find(whole, cancellation: DiskCancellation()).rootFailure, "duplicate scanner cannot use broad full-disk cleanup scope")
        let missing = try DiskScope(root: home.appendingPathComponent("Missing"), kind: .large, home: home)
        check(DuplicateScanner.find(missing, cancellation: DiskCancellation()).rootFailure, "missing duplicate root is not empty success")
        let blocked = folder.appendingPathComponent("Blocked")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        let deniedScope = try DiskScope(root: blocked, kind: .large, home: home)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let denied = DuplicateScanner.find(deniedScope, cancellation: DiskCancellation())
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        check(denied.rootFailure && !denied.errors.isEmpty, "real denied folder reports permission failure")
        var moves: [URL] = []
        let cleanup = DuplicateCleaner.trash(scan.groups, selected: [b.path, c.path], mover: { moves.append($0) })
        check(moves.count == 2 && !moves.contains(a) && cleanup.errors.isEmpty, "explicit cleanup processes only redundant copies")
        let all = DuplicateCleaner.trash(scan.groups, selected: [a.path, b.path, c.path], mover: { moves.append($0) })
        check(all.moved.isEmpty && !all.errors.isEmpty && moves.count == 2, "cannot clean retained file or all copies")
        let outside = DuplicateCleaner.trash(scan.groups, selected: ["/outside-scan.txt"], mover: { moves.append($0) })
        check(outside.moved.isEmpty && !outside.errors.isEmpty, "unknown selected paths rejected")
        if let group = scan.groups.first {
            let malformed = DuplicateGroup(digest: group.digest, files: [group.files[0], group.files[0]])
            let refused = DuplicateCleaner.trash([malformed], selected: [a.path], mover: { moves.append($0) })
            check(refused.moved.isEmpty && !refused.errors.isEmpty && moves.count == 2, "duplicate identity cannot masquerade as a redundant copy and delete the only original")
        } else { check(false, "group available for malformed input test") }
        let failed = DuplicateCleaner.trash(scan.groups, selected: [b.path], mover: { _ in throw DiskError.message("fixture Trash denied") })
        check(failed.moved.isEmpty && failed.errors.count == 1 && fm.fileExists(atPath: b.path), "duplicate Trash failure preserves source without permanent delete")
        try Data("abd".utf8).write(to: a)
        let changedKeeper = DuplicateCleaner.trash(scan.groups, selected: [b.path], mover: { moves.append($0) })
        check(changedKeeper.moved.isEmpty && !changedKeeper.errors.isEmpty && moves.count == 2, "changed keeper blocks cleanup even when copy is unchanged")
        try payload.write(to: a)
        let fresh = DuplicateScanner.find(scope, cancellation: DiskCancellation())
        try Data("abd".utf8).write(to: b)
        check(DuplicateCleaner.trash(fresh.groups, selected: [b.path], mover: { moves.append($0) }).moved.isEmpty, "changed duplicate rejected before move")
        var trashLocation: NSURL?
        let real = DuplicateCleaner.trash(fresh.groups, selected: [c.path], mover: {
            try fm.trashItem(at: $0, resultingItemURL: &trashLocation)
        })
        check(real.moved == [c] && fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: c.path),
              "real Trash removes only test-owned redundant copy while retaining original")
        if let trashURL = trashLocation as URL? {
            guard try Data(contentsOf: trashURL) == payload else { throw DiskError.message("Unexpected test-owned Trash content") }
            try fm.moveItem(at: trashURL, to: c)
            check(try Data(contentsOf: c) == payload, "test-owned duplicate restored from Trash intact")
        } else { check(false, "duplicate restoration URL returned") }
        let deepA = try write("large-first.bin", Data(repeating: 65, count: 2 * 1024 * 1024 + 7))
        var differing = Data(repeating: 65, count: 2 * 1024 * 1024 + 7); differing[differing.count - 1] = 66
        let deepB = try write("large-last-byte-different.bin", differing)
        let deepScan = DuplicateScanner.find(scope, cancellation: DiskCancellation())
        check(!deepScan.groups.contains { Set($0.files.map { $0.url.path }).isSuperset(of: [deepA.path, deepB.path]) }, "streaming comparison reads beyond first chunk and detects last-byte difference")
    } catch { check(false, "duplicate fixture: \(error.localizedDescription)") }
    do {
        check(try NetworkHealth.host("  WWW.APPLE.COM  ") == "www.apple.com", "target domain normalized")
        for input in ["", "https://example.com", "me@example.com", "example.com/path", "ex..com", "-bad.test", "bad-.test", "host:443", "中文.test", "x\r\nHost:evil"] {
            check(rejects { _ = try NetworkHealth.host(input) }, "reject non-domain target \(input.debugDescription)")
        }
        let good = HealthCheck(title: "fixture", level: .good, detail: "fixture success")
        let warning = HealthCheck(title: "fixture", level: .warning, detail: "HTTP 403")
        let bad = HealthCheck(title: "DNS", level: .failed, detail: "fixture DNS failure")
        let services = NetworkHealthServices(path: { _ in good }, configuration: { [] }, dns: { _ in good }, https: { _, _ in good })
        let run = try NetworkHealth.run("fixture.test", cancellation: DiskCancellation(), services: services)
        check(run.checks.count == 3 && run.summary == "本次目标检查通过", "network pipeline checks path, DNS and HTTPS")
        var dnsFailure = services; dnsFailure.dns = { _ in bad }
        check(try NetworkHealth.run("fixture.test", cancellation: DiskCancellation(), services: dnsFailure).summary == "发现需要排查的项目", "DNS failure cannot be hidden by successful HTTPS proxy path")
        var httpWarning = services; httpWarning.https = { _, _ in warning }
        check(try NetworkHealth.run("fixture.test", cancellation: DiskCancellation(), services: httpWarning).summary == "部分项目需要留意", "HTTP restriction is a warning rather than whole-network failure")
        let cancelled = DiskCancellation(); cancelled.cancel()
        check(try NetworkHealth.run("fixture.test", cancellation: cancelled, services: services).cancelled, "network pre-cancellation settles without requests")
        var mid = services; let during = DiskCancellation(); mid.dns = { _ in during.cancel(); return good }
        let partial = try NetworkHealth.run("fixture.test", cancellation: during, services: mid)
        check(partial.cancelled && partial.checks.count == 2, "cancellation after DNS prevents HTTPS step")
        check(run.report.contains("不是网速") && run.report.contains("单个目标"), "report explains latency and single-target limits")
        for code in [200, 301, 403, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://fixture.test/")!, statusCode: code, httpVersion: nil, headerFields: nil)!
            check(NetworkHealth.httpResult(response, error: nil, elapsed: 0.1).level == (code == 200 ? .good : .warning), "HTTP \(code) classified without claiming total outage")
        }
        check(NetworkHealth.httpResult(nil, error: URLError(.serverCertificateUntrusted), elapsed: 0).detail.contains("不会绕过"), "TLS error preserves certificate verification")
        check(NetworkHealth.httpResult(nil, error: URLError(.timedOut), elapsed: 0).detail.contains("超时"), "timeout produces actionable result")
        check(NetworkHealth.httpResult(nil, error: URLError(.cannotFindHost), elapsed: 0).detail.contains("DNS"), "resolution error has DNS-specific suggestion")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HealthTestProtocol.self]
        let url = URL(string: "https://fixture.test/")!
        HealthTestProtocol.mode.set(200)
        check(NetworkHealth.https(url, cancellation: DiskCancellation(), configuration: config).level == .good, "real URLSession pipeline accepts fixture HTTP 200")
        check(HealthTestProtocol.lastRequest.value?.httpMethod == "HEAD", "connectivity probe uses HEAD rather than download")
        check(HealthTestProtocol.lastRequest.value?.value(forHTTPHeaderField: "Cookie") == nil &&
              HealthTestProtocol.lastRequest.value?.value(forHTTPHeaderField: "Authorization") == nil, "probe does not attach stored cookies or credentials")
        HealthTestProtocol.mode.set(403)
        check(NetworkHealth.https(url, cancellation: DiskCancellation(), configuration: config).level == .warning, "URLSession restricted response is not global failure")
        HealthTestProtocol.mode.set(-1)
        check(NetworkHealth.https(url, cancellation: DiskCancellation(), configuration: config).detail.contains("证书"), "URLSession TLS failure translated without bypass")
        HealthTestProtocol.mode.set(0)
        let began = ProcessInfo.processInfo.systemUptime
        let timeout = NetworkHealth.https(url, cancellation: DiskCancellation(), configuration: config, timeout: 0.1)
        check(timeout.level == .failed && ProcessInfo.processInfo.systemUptime - began < 2, "unresponsive probe has bounded total deadline")
        let cancel = DiskCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancel.cancel() }
        let cancelBegan = ProcessInfo.processInfo.systemUptime
        _ = NetworkHealth.https(url, cancellation: cancel, configuration: config)
        check(ProcessInfo.processInfo.systemUptime - cancelBegan < 2, "cancellation stops in-flight HTTPS task")
        check(NetworkHealth.https(URL(string: "http://fixture.test/")!, cancellation: DiskCancellation()).level == .failed, "probe refuses cleartext target")
    } catch { check(false, "network fixture: \(error.localizedDescription)") }
    print("Tools: \(checks - failures)/\(checks) checks passed"); exit(failures == 0 ? 0 : 1)
}

func toolboxUISelfTest() {
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("MacPulseToolUI-" + UUID().uuidString)
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") tool UI: \(name)"); fflush(stdout) }
    func finish() { try? fm.removeItem(at: fixture); print("Tool UI: \(checks - failures)/\(checks) checks passed"); fflush(stdout); exit(failures == 0 ? 0 : 1) }
    do {
        let home = fixture.appendingPathComponent("home"), folder = home.appendingPathComponent("Documents")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] { try Data("test-owned UI duplicate sample".utf8).write(to: folder.appendingPathComponent(name)) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        delegate.duplicateTool = DuplicateTool(home: home)
        delegate.networkTool.runner = { host, token, progress in
            let good = HealthCheck(title: "本地连接", level: .good, detail: "测试样本：本地连接可用")
            let services = NetworkHealthServices(path: { _ in good }, configuration: { [] },
                dns: { _ in HealthCheck(title: "DNS", level: .good, detail: "测试样本：解析成功") },
                https: { _, _ in HealthCheck(title: "HTTPS", level: .warning, detail: "测试样本：HTTP 403，目标限制；不代表断网") })
            return try NetworkHealth.run(host, cancellation: token, services: services, progress: progress)
        }
        app.delegate = delegate
        let duplicates = delegate.duplicateTool, network = delegate.networkTool
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        func wait(_ next: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                if !duplicates.busy && !network.busy { next() }
                else if ProcessInfo.processInfo.systemUptime > deadline { check(false, "background tools settle"); finish() }
                else { wait(next) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check(delegate.modules.segmentCount == 5 && delegate.window.title.contains("1.4.0"), "five toolbox modules and correct version")
            delegate.modules.selectedSegment = 2; delegate.switchModule()
            check(!duplicates.view.isHidden && network.view.isHidden && delegate.diskTool.view.isHidden, "duplicate module switches without replacing controllers")
            check(duplicates.selected.isEmpty && !duplicates.scanButton.isEnabled && !duplicates.cleanButton.isEnabled, "duplicate scan requires explicit folder and never starts selected")
            do { try duplicates.useFolder(folder) } catch { check(false, "select UI fixture folder"); finish(); return }
            duplicates.scan()
            check(duplicates.busy && !duplicates.folderButton.isEnabled && duplicates.cancelButton.isEnabled, "duplicate background scan locks folder and supports cancel")
            delegate.modules.selectedSegment = 3; delegate.switchModule()
            check(duplicates.busy && !network.view.isHidden, "module switch leaves background duplicate scan running")
            network.start()
            check(network.busy && !network.target.isEnabled && network.cancelButton.isEnabled, "network request locks target while running")
            wait {
                check(duplicates.result.groups.count == 1 && duplicates.rows.count == 3 && duplicates.selected.isEmpty, "duplicate UI displays verified group without auto selection")
                duplicates.selectCopies()
                check(duplicates.selected.count == 2 && duplicates.cleanButton.isEnabled, "explicit select-copies retains one file")
                let keeper = duplicates.tableView(duplicates.table, viewFor: duplicates.table.tableColumns[0], row: 0) as? NSButton
                check(keeper?.isEnabled == false && keeper?.title == "保留", "retained-file checkbox cannot be selected")
                let attempted = NSButton(); attempted.tag = 0; duplicates.toggle(attempted)
                check(duplicates.selected.count == 2, "direct keeper action cannot add retained file")
                let previous = duplicates.selected
                delegate.modules.selectedSegment = 2; delegate.switchModule()
                delegate.modules.selectedSegment = 0; delegate.switchModule()
                delegate.modules.selectedSegment = 2; delegate.switchModule()
                check(duplicates.rows.count == 3 && duplicates.selected == previous, "module switching preserves duplicate results and selection")
                if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--tool-ui-preview=") }) {
                    do { try delegate.renderPreview(to: String(argument.dropFirst(18)) + "/duplicates.png") }
                    catch { check(false, "duplicate preview rendered") }
                }
                delegate.modules.selectedSegment = 3; delegate.switchModule()
                check(network.result?.checks.count == 3 && network.summary.stringValue == "部分项目需要留意", "network result preserves granular HTTP warning")
                check(!network.busy && network.target.isEnabled && !network.cancelButton.isEnabled, "network completion unlocks controls")
                network.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                check(network.detail.stringValue.contains("不代表断网"), "network selected row shows full explanation")
                delegate.modules.selectedSegment = 1; delegate.switchModule()
                delegate.modules.selectedSegment = 3; delegate.switchModule()
                check(network.result?.host == "www.apple.com" && network.table.numberOfRows == 3, "network snapshot survives switching modules")
                if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--tool-ui-preview=") }) {
                    do { try delegate.renderPreview(to: String(argument.dropFirst(18)) + "/network.png") }
                    catch { check(false, "network preview rendered") }
                }
                network.preset.selectItem(at: 1); network.changePreset()
                check(network.target.stringValue == "www.baidu.com", "preset supports alternate target for comparison")
                network.start(); network.cancel()
                wait {
                    check(network.result?.cancelled == true && !network.busy && network.startButton.isEnabled, "network cancellation settles without stale success")
                    duplicates.applyTrashResult(DuplicateTrashResult(moved: [folder.appendingPathComponent("b.txt")]))
                    check(duplicates.rows.isEmpty && !duplicates.cleanButton.isEnabled && duplicates.status.stringValue.contains("1 个副本"), "cleanup clears old duplicate evidence before next operation")
                    duplicates.scan(); duplicates.cancel()
                    wait {
                        check(!duplicates.busy && duplicates.cancellation == nil && duplicates.scanButton.isEnabled, "duplicate cancellation unlocks scanner")
                        finish()
                    }
                }
            }
        }
        app.run()
    } catch { check(false, error.localizedDescription); finish() }
}
