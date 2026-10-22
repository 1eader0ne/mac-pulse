import AppKit
import Darwin

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}
func selfTest(_ fixturePath: String?) {
    var failures = 0, checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }
    check(rate(200, 100, 2) == 50, "rate uses elapsed time")
    check(rate(99, 100, 2) == nil, "counter reset is unavailable")
    check(rate(100, 10, 0) == nil, "zero interval is unavailable")
    check(applicationRoot("/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/Editor.app", "nested helper groups with parent application")
    check(applicationRoot("/usr/bin/sleep") == nil, "CLI is not an application")
    func fake(_ pid: Int32 = 99999, uid: UInt32 = geteuid(), cpu: UInt64 = 0, start: UInt64 = 10) -> ProcessRow {
        var raw = MPProcess(); raw.pid = pid; raw.uid = uid; raw.start_sec = start; raw.cpu_ns = cpu; raw.cpu_valid = 1
        let path = "/Applications/TestFixture.app/Contents/MacOS/TestFixture"
        withUnsafeMutableBytes(of: &raw.path) { bytes in path.withCString { p in _ = memcpy(bytes.baseAddress!, p, path.utf8.count + 1) } }
        return ProcessRow(raw)
    }
    let row = fake()
    check(Protection.allowed(row, appPath: "/Applications/TestFixture.app", bundleID: "test.fixture"), "eligible user app allowed")
    check(!Protection.allowed(fake(uid: 0), appPath: "/Applications/TestFixture.app", bundleID: "test.fixture"), "root process protected")
    check(!Protection.allowed(fake(uid: geteuid() + 1), appPath: "/Applications/TestFixture.app", bundleID: "test.fixture"), "other user protected")
    check(!Protection.allowed(row, appPath: "/Applications/TestFixture.app", bundleID: "com.apple.finder"), "Apple system app protected")
    check(!Protection.allowed(row, appPath: "/Applications/TestFixture.app", bundleID: productID), "own bundle protected")
    check(!Protection.same(row, fake(start: 11)), "PID reuse detected")
    let old = Snapshot(time: 1, rows: [row], interfaces: [], system: MPSystem(), truncated: false)
    let now = Snapshot(time: 3, rows: [fake(cpu: 1_000_000_000)], interfaces: [], system: MPSystem(), truncated: false)
    check(measured(now, after: old).rows[0].cpu == 50, "CPU 100 percent means one core")
    check(measured(now, after: nil).rows[0].cpu == nil, "first sample has no CPU rate")
    let reused = Snapshot(time: 3, rows: [fake(cpu: 1_000_000_000, start: 11)], interfaces: [], system: MPSystem(), truncated: false)
    check(measured(reused, after: old).rows[0].cpu == nil, "new process gets no stale CPU")
    let g = AppGroup(key: "test", name: "Test", path: "/Applications/TestFixture.app", rows: [row], main: row, bundleID: "test.fixture", cpu: 95, memory: 0, incomplete: false)
    let detector = Detector()
    check(detector.update([g], time: 1, threshold: 80)[0].sustained == 0, "first spike not sustained")
    for t in stride(from: 3.0, through: 15, by: 2) { _ = detector.update([g], time: t, threshold: 80) }
    check(detector.update([g], time: 17, threshold: 80)[0].sustained == 16, "continuous load tracked")
    check(detector.update([g], time: 40, threshold: 80)[0].sustained == 0, "sleep gap resets evidence")
    let high = InterfaceSample(name: "utun9", packets: 0, bytes: 0, packetRate: 160000, byteRate: 0)
    check(networkEvidence([high]).contains("需进一步核实"), "network anomaly is hypothesis")
    check(!networkEvidence([InterfaceSample(name: "utun9", packets: 0, bytes: 0)]).contains("疑似"), "first network sample not anomalous")
    let first = Snapshot.capture(); pump(0.25); let live = measured(Snapshot.capture(), after: first)
    check(live.rows.contains { $0.identity.pid == getpid() && $0.cpu != nil }, "native live process sampling")
    check(live.system.physical > 0, "physical memory read")
    check(live.totalCPU != nil, "system CPU delta read")
    check(Protection.allowed(ProcessRow.live(getpid())!, appPath: Bundle.main.bundlePath, bundleID: productID) == false, "live own process protected")
    let systemFallback = ProcessRow(psFields: ["90000", "1", "501", "95.0", "100", "/Applications/TestFixture.app/Contents/MacOS/TestFixture"])
    check(!Protection.allowed(systemFallback, appPath: "/Applications/TestFixture.app", bundleID: "test.fixture"), "fallback process cannot be terminated")
    // A real busy single-threaded process verifies the Apple Silicon timebase.
    let burner = Process(); burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    burner.standardOutput = FileHandle.nullDevice; burner.standardError = FileHandle.nullDevice
    do {
        try burner.run(); pump(0.2)
        let before = Snapshot.capture(); pump(1.5)
        let after = measured(Snapshot.capture(), after: before)
        let usage = after.rows.first { $0.identity.pid == burner.processIdentifier }?.cpu ?? -1
        print(String(format: "Measured busy single core: %.1f%%", usage))
        check(usage > 50 && usage < 130, "real CPU counter unit conversion")
        // Only the test-owned subprocess is terminated here.
        burner.terminate(); pump(0.2)
    } catch { check(false, "busy CPU fixture started") }
    if let fixturePath = fixturePath {
        _ = NSApplication.shared
        for force in [false, true] {
            let task = Process(); task.executableURL = URL(fileURLWithPath: fixturePath); task.arguments = ["--test-fixture"]
            do { try task.run() } catch { check(false, "start isolated fixture"); continue }
            pump(1.5)
            if let proc = ProcessRow.live(task.processIdentifier), let app = NSRunningApplication(processIdentifier: task.processIdentifier), let path = app.bundleURL?.path, let id = app.bundleIdentifier {
                let group = AppGroup(key: path, name: "TestFixture", path: path, rows: [proc], main: proc, bundleID: id, cpu: nil, memory: proc.memory, incomplete: false)
                if let target = CleanupTarget(group) {
                    let result = requestQuit(target, force: force)
                    if case .requested = result { check(true, "\(force ? "force" : "normal") quit accepted") }
                    else { check(false, "fixture quit accepted") }
                    pump(1)
                    check(!targetStillRunning(target), "\(force ? "force" : "normal") quit verified")
                } else { check(false, "fixture cleanup target eligible") }
            } else { check(false, "fixture registered as running application") }
            // Only this test-owned subprocess can be cleaned up by this fallback.
            if task.isRunning { task.terminate(); pump(0.5) }
        }
    } else { check(false, "integration fixture path supplied") }
    print("\(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}
let args = CommandLine.arguments
if args.contains("--test-fixture") {
    let app = NSApplication.shared; let delegate = FixtureDelegate()
    app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
} else if args.contains("--uninstall-selftest") {
    uninstallSelfTest()
} else if args.contains("--uninstall-ui-selftest") {
    uninstallUISelfTest()
} else if args.contains("--tool-selftest") {
    toolboxSelfTest()
} else if args.contains("--packet-selftest") {
    packetCaptureSelfTest()
} else if let fixture = args.first(where: { $0.hasPrefix("--capture-residue-fixture=") }) {
    captureResidueFixture(String(fixture.dropFirst("--capture-residue-fixture=".count)))
} else if args.contains("--packet-ui-selftest") {
    packetCaptureUISelfTest()
} else if args.contains("--tool-ui-selftest") {
    toolboxUISelfTest()
} else if args.contains("--network-probe") {
    do { print(try NetworkHealth.run("www.apple.com", cancellation: DiskCancellation()).report) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.contains("--disk-ui-selftest") {
    diskUISelfTest()
} else if args.contains("--disk-selftest") {
    diskSelfTest()
} else if args.contains("--selftest") {
    selfTest(args.first(where: { $0.hasPrefix("--fixture=") }).map { String($0.dropFirst(10)) })
} else if args.contains("--probe") {
    let first = Snapshot.capture(); pump(2)
    let sample = measured(Snapshot.capture(), after: first)
    let output: [String: Any] = ["processes": sample.rows.count, "readableCPU": sample.rows.filter { $0.cpu != nil }.count,
                               "systemCPU": sample.totalCPU as Any? ?? NSNull(), "samplingMS": sample.duration * 1000,
                               "top": sample.rows.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(8).map { ["pid": $0.identity.pid, "name": $0.name, "cpu": $0.cpu as Any? ?? NSNull()] as [String: Any] },
                               "network": sample.interfaces.map { ["name": $0.name, "pps": $0.packetRate as Any? ?? NSNull()] as [String: Any] }]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
} else {
    let app = NSApplication.shared; let delegate = AppDelegate()
    delegate.networkTool.capture.cleanupStaleCaptures()
    app.setActivationPolicy(.regular); app.delegate = delegate
    if let option = args.first(where: { $0.hasPrefix("--snapshot=") }) {
        let path = String(option.dropFirst(11))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            do { try delegate.renderPreview(to: path); print("Rendered: \(path)") }
            catch { print("Preview failed: \(error)") }
            app.terminate(nil)
        }
    }
    app.run()
}
