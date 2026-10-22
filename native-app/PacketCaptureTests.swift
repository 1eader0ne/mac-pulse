import AppKit

func captureFixture(_ payload: Data, link: UInt32 = 1, little: Bool = true, nano: Bool = false) -> Data {
    var data = Data()
    func word(_ value: UInt32) {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        data.append(contentsOf: little ? bytes : bytes.reversed())
    }
    word(nano ? 0xa1b23c4d : 0xa1b2c3d4)
    data.append(contentsOf: little ? [2, 0, 4, 0] : [0, 2, 0, 4])
    word(0); word(0); word(1518); word(link)
    word(1_700_000_000); word(nano ? 123_000_000 : 123_000); word(UInt32(payload.count)); word(UInt32(payload.count + 10))
    data.append(payload); return data
}
func captureTCPFixture() -> Data {
    var b = [UInt8](repeating: 0, count: 54)
    b[12] = 8; b[14] = 0x45; b[17] = 40; b[23] = 6
    b.replaceSubrange(26..<30, with: [192, 0, 2, 1]); b.replaceSubrange(30..<34, with: [198, 51, 100, 2])
    b[34] = 0xc3; b[35] = 0x50; b[36] = 1; b[37] = 0xbb; b[46] = 0x50; b[47] = 0x12
    return Data(b)
}

// Deliberately bypass Swift deinitializers, as a crash/forced quit would do.
func captureResidueFixture(_ path: String) {
    do {
        let job = try PacketCaptureJob(options: CaptureOptions(interface: "lo0", filter: ""), temporaryRoot: URL(fileURLWithPath: path))
        try captureFixture(captureTCPFixture()).write(to: job.file)
        withExtendedLifetime(job) { Darwin._exit(0) }
    } catch { Darwin._exit(1) }
}

func packetCaptureSelfTest() {
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") capture: \(name)") }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacPulseCaptureTest-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        check(!CaptureOptions.interfaces().isEmpty, "local interface inventory available without opening BPF")
        let options = try CaptureOptions(interface: "lo0", filter: "  tcp port 443  ")
        let cleanupRoot = root.appendingPathComponent("cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: false)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func residue(lease: Bool = true, old: Bool = false) throws -> URL {
            let directory = cleanupRoot.appendingPathComponent(CaptureTemporaryFiles.prefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try captureFixture(captureTCPFixture()).write(to: directory.appendingPathComponent("capture.pcap"))
            try Data().write(to: directory.appendingPathComponent("active"))
            if lease { Darwin.close(try CaptureTemporaryFiles.createLease(in: directory)) }
            if old {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: directory.appendingPathComponent(name).path)
                }
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: directory.path)
            }
            return directory
        }
        let orphan = try residue()
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 1 && !exists(orphan), "unlocked abandoned capture is removed immediately")
        let live = try PacketCaptureJob(options: options, temporaryRoot: cleanupRoot)
        try captureFixture(captureTCPFixture()).write(to: live.file)
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 0 && exists(live.file), "active session lease protects capture from another cleanup")
        live.stop()
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 0 && exists(live.file), "finished results stay protected until cleared or exported")
        let legacy = try residue(lease: false, old: true), recent = try residue(lease: false)
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 1 && !exists(legacy) && exists(recent), "legacy records age out after 24 hours while fresh records remain")
        let touched = try residue(lease: false, old: true)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: touched.appendingPathComponent("capture.pcap").path)
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 0 && exists(touched), "recent packet writes protect an old legacy directory")
        let exported = root.appendingPathComponent("exported.pcap")
        let savedBytes = captureFixture(captureTCPFixture()); try savedBytes.write(to: exported)
        let extra = try residue(); try savedBytes.write(to: extra.appendingPathComponent("exported.pcap"))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("personal.pcap"); try savedBytes.write(to: sentinel)
        let linkedDir = cleanupRoot.appendingPathComponent(CaptureTemporaryFiles.prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: outside)
        let linkedFile = try residue()
        try FileManager.default.removeItem(at: linkedFile.appendingPathComponent("capture.pcap"))
        try FileManager.default.createSymbolicLink(at: linkedFile.appendingPathComponent("capture.pcap"), withDestinationURL: sentinel)
        let hardLinked = try residue()
        try FileManager.default.removeItem(at: hardLinked.appendingPathComponent("capture.pcap"))
        try FileManager.default.linkItem(at: sentinel, to: hardLinked.appendingPathComponent("capture.pcap"))
        let invalidLease = try residue(); try Data("unrelated lock".utf8).write(to: invalidLease.appendingPathComponent("lease"))
        let publicDir = try residue(); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicDir.path)
        let report = CaptureTemporaryFiles.cleanup(root: cleanupRoot)
        check(report.removed == 0 && exists(extra) && exists(invalidLease) && exists(publicDir), "unknown files, invalid lease and unexpected directory permissions are preserved")
        check(try Data(contentsOf: exported) == savedBytes && Data(contentsOf: sentinel) == savedBytes && exists(linkedFile) && exists(hardLinked), "cleanup preserves manual exports and never follows symbolic or hard links")
        let empty = try residue()
        try FileManager.default.removeItem(at: empty.appendingPathComponent("capture.pcap"))
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 1 && !exists(empty), "crash before first packet is cleaned too")
        let crashed = Process(); crashed.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        crashed.arguments = ["--capture-residue-fixture=" + cleanupRoot.path]
        try crashed.run(); crashed.waitUntilExit()
        check(crashed.terminationStatus == 0 && CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 1, "process exit without deinit releases lease and next launch cleans residue")
        check(CaptureTemporaryFiles.cleanup(root: cleanupRoot).removed == 0 && exists(live.file), "repeated cleanup is idempotent and preserves another instance's results")
        let linkedRoot = root.appendingPathComponent("linked-cleanup-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: cleanupRoot)
        check(CaptureTemporaryFiles.cleanup(root: linkedRoot).failed == 1 && exists(live.file), "cleanup refuses a symlink as its root")
        check(options.filter == "tcp port 443" && options.arguments.contains("-p") && options.arguments.contains("5000"), "bounded non-promiscuous capture arguments")
        for name in ["", "-i", "en0;id", "en0\n", "x/y"] {
            check(rejects { _ = try CaptureOptions(interface: name, filter: "") }, "reject invalid interface \(name.debugDescription)")
        }
        for filter in ["-w /tmp/unwanted", "tcp\nport 443", "\u{0}", String(repeating: "a", count: 513)] {
            check(rejects { _ = try CaptureOptions(interface: "lo0", filter: filter) }, "reject invalid filter input")
        }
        check(rejects { _ = try CaptureOptions(interface: "lo0", filter: "", seconds: 0) }, "unbounded duration refused")
        check(rejects { _ = try CaptureOptions(interface: "lo0", filter: "", snapshot: 65535) }, "oversized capture refused")
        let packet = captureTCPFixture()
        for little in [true, false] {
            for nano in [false, true] {
                var stream = PCAPStream(), decoded: [CapturedPacket] = []
                for byte in captureFixture(packet, little: little, nano: nano) { decoded += try stream.append(Data([byte])) }
                check(stream.complete && decoded.count == 1, "partial reads decode \(little ? "little" : "big") endian \(nano ? "nano" : "micro") PCAP")
                check(decoded.first?.source == "192.0.2.1:50000" && decoded.first?.destination == "198.51.100.2:443", "IPv4 TCP endpoints and ports")
                check(decoded.first?.protocolName == "TCP" && decoded.first?.summary.contains("SYN ACK") == true, "TCP flags and protocol decoded")
                check(abs((decoded.first?.timestamp.timeIntervalSince1970 ?? 0) - 1_700_000_000.123) < 0.00001, "PCAP timestamp precision")
            }
        }
        var stream = PCAPStream()
        let decoded = try stream.append(captureFixture(packet))
        check(decoded[0].detail.contains("0000") && decoded[0].detail.contains("保存 54 字节"), "hex detail includes captured length")
        check(decoded[0].summary.contains("54/64"), "snaplen truncation made explicit")
        var incomplete = PCAPStream(); _ = try incomplete.append(Data(captureFixture(packet).dropLast()))
        check(!incomplete.complete && incomplete.count == 0, "partial record not counted or exportable")
        var malformed = PCAPStream()
        check(rejects { _ = try malformed.append(Data(repeating: 0, count: 24)) }, "invalid file magic refused")
        var badLength = captureFixture(packet); badLength.replaceSubrange(32..<36, with: [255, 255, 255, 127])
        var invalid = PCAPStream(); check(rejects { _ = try invalid.append(badLength) }, "malformed record length refused before allocation")
        var loopback = PCAPStream()
        let loop = try loopback.append(captureFixture(Data([2, 0, 0, 0]) + packet.dropFirst(14), link: 0))
        check(loop.first?.source == "192.0.2.1:50000", "macOS loopback link layer decoded")
        var raw = PCAPStream()
        check(try raw.append(captureFixture(Data(packet.dropFirst(14)), link: 12)).first?.protocolName == "TCP", "VPN raw IP link layer decoded")
        var fragment = packet; fragment[20] = 0; fragment[21] = 1
        var fragments = PCAPStream(); let frag = try fragments.append(captureFixture(fragment))
        check(frag.first?.source == "192.0.2.1" && frag.first?.summary.contains("分片") == true, "non-initial IPv4 fragments never become fake ports")
        var ipv6 = [UInt8](repeating: 0, count: 52); ipv6[0] = 0x60; ipv6[6] = 17
        ipv6[23] = 1; ipv6[39] = 2; ipv6[40] = 0; ipv6[41] = 53; ipv6[42] = 0xc3; ipv6[43] = 0x50
        var v6 = PCAPStream(); let udp = try v6.append(captureFixture(Data(ipv6), link: 12))
        check(udp.first?.source == "[::1]:53" && udp.first?.protocolName == "UDP" && udp.first?.summary.contains("DNS") == true, "IPv6 UDP addresses preserve port boundaries")
        for size in 0..<60 {
            _ = CapturedPacket(number: 1, timestamp: Date(), originalLength: size, bytes: Data(packet.prefix(size)), linkType: 1)
        }
        check(true, "short Ethernet and IP headers never read out of bounds")

        let job = try PacketCaptureJob(options: options)
        let attributes = try FileManager.default.attributesOfItem(atPath: job.directory.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "session storage private to current user")
        check(job.command.contains("'-Z' '\(NSUserName())'") && job.command.contains("'-p'") && job.command.contains("remaining=30"), "privileged launch drops identity before output and includes deadline")
        let injection = "tcp; /usr/bin/touch \(root.appendingPathComponent("injected").path) ' $(id)"
        let quoteTest = Process(), quoteOut = Pipe()
        quoteTest.executableURL = URL(fileURLWithPath: "/bin/sh")
        quoteTest.arguments = ["-c", "printf '%s' " + PacketCaptureJob.quote(injection)]
        quoteTest.standardOutput = quoteOut; try quoteTest.run(); quoteTest.waitUntilExit()
        check(String(decoding: quoteOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == injection && !FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path), "shell metacharacters remain literal data")
        let marker = root.appendingPathComponent("active"); try Data().write(to: marker)
        let supervised = Process(); supervised.executableURL = URL(fileURLWithPath: "/bin/sh")
        supervised.arguments = ["-c", PacketCaptureJob.supervisedCommand("/bin/sleep 20", control: marker, seconds: 1)]
        let began = Date(); try supervised.run(); supervised.waitUntilExit()
        check(Date().timeIntervalSince(began) < 5, "watchdog deadline stops an idle child without packets")
        try FileManager.default.removeItem(at: marker)
        let late = Process(); late.executableURL = URL(fileURLWithPath: "/bin/sh")
        late.arguments = ["-c", PacketCaptureJob.supervisedCommand("/usr/bin/touch " + PacketCaptureJob.quote(root.appendingPathComponent("late").path), control: marker, seconds: 1)]
        try late.run(); late.waitUntilExit()
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late").path), "cancelled authorization cannot start capture later")
        job.stop(); check(job.cancellation.cancelled && !FileManager.default.fileExists(atPath: job.control.path), "stop removes watchdog marker immediately")
        var called = false
        job.run { event in if case .finished(_, false) = event { called = true } }
        check(called && !FileManager.default.fileExists(atPath: job.file.path), "pre-cancelled job settles without authorization or packets")

        let saved = root.appendingPathComponent("sample.pcap"); try captureFixture(packet).write(to: saved)
        let decoder = Process(), output = Pipe(); decoder.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
        decoder.arguments = ["-nn", "-r", saved.path]; decoder.standardOutput = output; decoder.standardError = output
        try decoder.run(); decoder.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(decoder.terminationStatus == 0 && text.contains("192.0.2.1.50000"), "generated PCAP is readable by system tcpdump without privilege")

        let replay = try PacketCaptureJob(options: options)
        var observed: [CapturedPacket] = [], completed = false, opened = false
        replay.run(launcher: { _ in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
            process.arguments = ["-n", "-r", saved.path, "-w", replay.file.path]; return process
        }) { event in
            switch event {
            case .started: opened = true
            case .packets(let batch): observed += batch
            case .finished(_, let valid): completed = valid
            }
        }
        check(opened && completed && observed.count == 1 && observed.first?.source == "192.0.2.1:50000", "real process-to-file capture pipeline decodes a tcpdump replay")
        check(!FileManager.default.fileExists(atPath: replay.control.path), "completed capture removes watchdog marker")
        let denied = try PacketCaptureJob(options: options); var failed = false
        denied.run(launcher: { _ in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/false"); return process
        }) { event in if case .finished(_, false) = event { failed = true } }
        check(failed, "launcher failure without output never becomes successful capture")
    } catch { check(false, error.localizedDescription) }
    print("Capture: \(checks - failures)/\(checks) checks passed"); exit(failures == 0 ? 0 : 1)
}

func packetCaptureUISelfTest() {
    var checks = 0, failures = 0
    func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") capture UI: \(name)"); fflush(stdout) }
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = AppDelegate(), tool = delegate.networkTool.capture
    tool.cleanup = { CaptureCleanupReport(removed: 2) }
    tool.cleanupStaleCaptures()
    tool.runner = { job, callback in
        do {
            let data = captureFixture(captureTCPFixture()); try data.write(to: job.file)
            var reader = PCAPStream(); callback(.started); callback(.packets(try reader.append(data)))
            while !job.cancellation.cancelled { Thread.sleep(forTimeInterval: 0.02) }
            callback(.finished("样本抓包已停止", true))
        } catch { callback(.finished(error.localizedDescription, false)) }
    }
    app.delegate = delegate
    func finish() { tool.shutdown(); tool.clear(); print("Capture UI: \(checks - failures)/\(checks) checks passed"); fflush(stdout); exit(failures == 0 ? 0 : 1) }
    let deadline = Date().addingTimeInterval(10)
    func wait(_ ready: @escaping () -> Bool, _ next: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if ready() { next() }
            else if Date() > deadline { check(false, "capture worker settles"); finish() }
            else { wait(ready, next) }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        delegate.modules.selectedSegment = 3; delegate.switchModule()
        let network = delegate.networkTool
        check(tool.status.stringValue.contains("已清理 2 份"), "startup cleanup result is visible without starting a capture")
        check(!network.healthView.isHidden && tool.view.isHidden, "connection checks remain the default")
        network.modes.selectedSegment = 1; network.switchMode()
        check(network.healthView.isHidden && !tool.view.isHidden && !tool.busy && !tool.exportButton.isEnabled, "capture requires an explicit start")
        tool.preset.selectItem(at: 4); tool.changePreset()
        check(tool.filter.stringValue == "tcp port 443 or udp port 443", "HTTPS preset includes QUIC port")
        tool.start()
        check(tool.busy && !tool.interface.isEnabled && !tool.startButton.isEnabled && tool.stopButton.isEnabled, "active capture locks settings and enables stop")
        wait({ tool.packets.count == 1 }) {
            tool.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            check(tool.detail.string.contains("192.0.2.1:50000") && tool.table.numberOfRows == 1, "live table selection shows packet detail")
            network.modes.selectedSegment = 0; network.switchMode(); delegate.modules.selectedSegment = 0; delegate.switchModule()
            check(tool.busy && tool.packets.count == 1, "capture and results survive both levels of navigation")
            delegate.modules.selectedSegment = 3; delegate.switchModule(); network.modes.selectedSegment = 1; network.switchMode()
            tool.stop()
            check(!tool.stopButton.isEnabled && !tool.exportButton.isEnabled, "stopping waits for finalized file before export")
            wait({ !tool.busy }) {
                check(tool.exportButton.isEnabled && tool.startButton.isEnabled && tool.interface.isEnabled, "finished capture unlocks settings and export")
                if let job = tool.job {
                    let path = job.directory.appendingPathComponent("export.pcap")
                    do {
                        try tool.export(to: path)
                        check(try Data(contentsOf: path) == Data(contentsOf: job.file), "export preserves exact original PCAP bytes")
                    } catch { check(false, "PCAP export: \(error.localizedDescription)") }
                } else { check(false, "finished session retained for export") }
                if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-ui-preview=") }) {
                    do { try delegate.renderPreview(to: String(arg.dropFirst("--capture-ui-preview=".count))) }
                    catch { check(false, "capture preview: \(error.localizedDescription)") }
                }
                let oldPath = tool.job?.directory.path ?? ""
                tool.clear()
                // The completion callback can still hold the job until this run-loop iteration returns.
                DispatchQueue.main.async {
                    check(tool.packets.isEmpty && !tool.exportButton.isEnabled && tool.job == nil, "clear discards session and disables export")
                    check(!FileManager.default.fileExists(atPath: oldPath), "clearing removes private temporary packet data")
                    tool.runner = { _, callback in callback(.finished("已取消系统授权。", false)) }
                    tool.start()
                    wait({ !tool.busy }) {
                        check(tool.status.stringValue.contains("取消系统授权") && !tool.exportButton.isEnabled, "authorization failure is visible and cannot export an absent file")
                        finish()
                    }
                }
            }
        }
    }
    app.run()
}
