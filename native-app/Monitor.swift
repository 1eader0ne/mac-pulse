import AppKit
import Darwin

let productID = "com.hb.macpulse"
let accent = NSColor(calibratedRed: 0.10, green: 0.49, blue: 0.52, alpha: 1)
func cString<T>(_ value: T) -> String {
    var copy = value
    return withUnsafeBytes(of: &copy) { bytes in
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes.prefix(end), as: UTF8.self)
    }
}
func byteText(_ value: UInt64) -> String {
    if value == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}
struct ProcessIdentity: Hashable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
}
struct ProcessRow {
    let identity: ProcessIdentity
    let parent: Int32
    let uid: UInt32
    let name: String
    let path: String
    let cpuNS: UInt64
    let memory: UInt64
    let readable: Bool
    var cpu: Double? = nil
    var smoothed = false
    init(_ raw: MPProcess) {
        identity = .init(pid: raw.pid, seconds: raw.start_sec, microseconds: raw.start_usec)
        parent = raw.ppid; uid = raw.uid; name = cString(raw.name); path = cString(raw.path)
        cpuNS = raw.cpu_ns; memory = raw.resident; readable = raw.cpu_valid != 0
    }
    static func live(_ pid: Int32) -> ProcessRow? {
        var raw = MPProcess()
        return mp_process(pid, &raw) == 1 ? ProcessRow(raw) : nil
    }
    init(psFields: [String]) {
        identity = .init(pid: Int32(psFields[0]) ?? -1, seconds: 0, microseconds: 0)
        parent = Int32(psFields[1]) ?? 0; uid = UInt32(psFields[2]) ?? UInt32.max
        path = psFields[5]; name = URL(fileURLWithPath: path).lastPathComponent
        cpuNS = 0; memory = (UInt64(psFields[4]) ?? 0) * 1024; readable = true
        cpu = Double(psFields[3]); smoothed = true
    }
}
struct InterfaceSample {
    let name: String
    let packets: UInt64
    let bytes: UInt64
    var packetRate: Double? = nil
    var byteRate: Double? = nil
}
struct Snapshot {
    let time: Double
    var rows: [ProcessRow]
    var interfaces: [InterfaceSample]
    let system: MPSystem
    var totalCPU: Double? = nil
    var duration: Double = 0
    let truncated: Bool
    static func capture() -> Snapshot {
        let begin = ProcessInfo.processInfo.systemUptime
        let capacity = 8192
        let pointer = UnsafeMutablePointer<MPProcess>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        let count = mp_processes(pointer, Int32(capacity))
        var rows = count > 0 ? (0..<Int(count)).map { ProcessRow(pointer[$0]) } : []
        // Apple's setuid ps can read system services that libproc denies to user apps.
        // Only add unavailable PIDs; cleanup never accepts these identities.
        let known = Set(rows.map { $0.identity.pid })
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe(); process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain while the child writes, to avoid pipe buffer deadlock.
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let fields = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    if fields.count == 6, let pid = Int32(fields[0]), pid > 0, pid != process.processIdentifier, !known.contains(pid) {
                        rows.append(ProcessRow(psFields: fields))
                    }
                }
            }
        } catch { /* Native data remains usable; UI reports missing CPU explicitly. */ }
        let net = UnsafeMutablePointer<MPNetwork>.allocate(capacity: 128)
        defer { net.deallocate() }
        let nc = mp_networks(net, 128)
        let interfaces = nc > 0 ? (0..<Int(nc)).map { i in
            InterfaceSample(name: cString(net[i].name), packets: net[i].in_packets &+ net[i].out_packets,
                            bytes: net[i].in_bytes &+ net[i].out_bytes)
        } : []
        return Snapshot(time: begin, rows: rows, interfaces: interfaces, system: mp_system(),
                        duration: ProcessInfo.processInfo.systemUptime - begin, truncated: count >= capacity)
    }
}
func rate(_ current: UInt64, _ old: UInt64, _ elapsed: Double) -> Double? {
    guard elapsed > 0, current >= old else { return nil }
    return Double(current - old) / elapsed
}
func measured(_ current: Snapshot, after old: Snapshot?) -> Snapshot {
    guard let old = old, current.time > old.time else { return current }
    var result = current
    let delta = current.time - old.time
    let previous = Dictionary(uniqueKeysWithValues: old.rows.map { ($0.identity, $0) })
    for i in result.rows.indices {
        let row = result.rows[i]
        if row.readable, !row.smoothed, let prev = previous[row.identity], prev.readable, !prev.smoothed {
            result.rows[i].cpu = rate(row.cpuNS, prev.cpuNS, delta).map { $0 / 1_000_000_000 * 100 }
        }
    }
    let net = Dictionary(uniqueKeysWithValues: old.interfaces.map { ($0.name, $0) })
    for i in result.interfaces.indices {
        if let prev = net[result.interfaces[i].name] {
            result.interfaces[i].packetRate = rate(result.interfaces[i].packets, prev.packets, delta)
            result.interfaces[i].byteRate = rate(result.interfaces[i].bytes, prev.bytes, delta)
        }
    }
    let a = current.system, b = old.system
    if a.cpu_valid != 0, b.cpu_valid != 0 {
        let totalA = a.user_ticks + a.system_ticks + a.nice_ticks + a.idle_ticks
        let totalB = b.user_ticks + b.system_ticks + b.nice_ticks + b.idle_ticks
        if totalA > totalB, a.idle_ticks >= b.idle_ticks {
            result.totalCPU = max(0, min(100, (1 - Double(a.idle_ticks - b.idle_ticks) / Double(totalA - totalB)) * 100))
        }
    }
    return result
}
func applicationRoot(_ path: String) -> String? {
    guard let end = path.range(of: ".app/") else { return nil }
    return String(path[..<end.lowerBound]) + ".app"
}
struct AppGroup {
    let key: String
    let name: String
    let path: String
    let rows: [ProcessRow]
    let main: ProcessRow?
    let bundleID: String?
    let cpu: Double?
    let memory: UInt64
    let incomplete: Bool
    var sustained: Double = 0
    var canQuit: Bool {
        guard let main = main, let id = bundleID else { return false }
        return Protection.allowed(main, appPath: path, bundleID: id)
    }
}
enum Protection {
    static func allowed(_ row: ProcessRow, appPath: String, bundleID: String) -> Bool {
        row.identity.pid > 1 && row.identity.pid != getpid() && row.identity.seconds > 0 && !row.smoothed && row.uid == geteuid()
        && row.uid != 0 && !row.path.isEmpty && !bundleID.isEmpty && bundleID != productID
        && !bundleID.hasPrefix("com.apple.") && !appPath.hasPrefix("/System/")
        && !appPath.hasPrefix("/usr/") && !appPath.hasPrefix("/Library/")
        && applicationRoot(row.path) == appPath
    }
    static func same(_ expected: ProcessRow, _ actual: ProcessRow) -> Bool {
        expected.identity == actual.identity && expected.uid == actual.uid && expected.path == actual.path
    }
}
func groups(_ rows: [ProcessRow], applications: [NSRunningApplication]) -> [AppGroup] {
    let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity.pid, $0) })
    let apps = Dictionary(applications.compactMap { app -> (Int32, NSRunningApplication)? in
        guard !app.isTerminated else { return nil }
        return (app.processIdentifier, app)
    }, uniquingKeysWith: { a, _ in a })
    var buckets: [String: [ProcessRow]] = [:]
    var roots: [String: String] = [:]
    for row in rows {
        var root = applicationRoot(row.path)
        var parent = row.parent
        var visited: Set<Int32> = [row.identity.pid]
        // Command-line helper processes inherit an application's group through live ancestry.
        while root == nil, parent > 1, visited.insert(parent).inserted, let p = byPID[parent] {
            root = applicationRoot(p.path); parent = p.parent
        }
        let key = root ?? "pid:\(row.identity.pid):\(row.identity.seconds):\(row.identity.microseconds)"
        buckets[key, default: []].append(row); roots[key] = root ?? row.path
    }
    return buckets.map { key, list in
        let main = list.first { apps[$0.identity.pid]?.bundleURL?.path == roots[key] }
        let app = main.flatMap { apps[$0.identity.pid] }
        let path = roots[key] ?? ""
        let totalCPU = list.compactMap(\.cpu)
        return AppGroup(key: key, name: app?.localizedName ?? (key.hasPrefix("pid:") ? list[0].name : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                        path: path, rows: list, main: main, bundleID: app?.bundleIdentifier,
                        cpu: totalCPU.isEmpty ? nil : totalCPU.reduce(0, +), memory: list.reduce(0) { $0 &+ $1.memory },
                        incomplete: list.contains { $0.cpu == nil || !$0.readable })
    }
}
final class Detector {
    private var beginnings: [String: (identity: ProcessIdentity, time: Double)] = [:]
    private var lastTime: Double? = nil
    func reset() { beginnings.removeAll(); lastTime = nil }
    func update(_ list: [AppGroup], time: Double, threshold: Double) -> [AppGroup] {
        // Sleep or a stalled sampler must not count as continuous high CPU evidence.
        if let old = lastTime, time - old > 8 { beginnings.removeAll() }
        lastTime = time
        var keep: [String: (identity: ProcessIdentity, time: Double)] = [:]
        let result = list.map { group -> AppGroup in
            var g = group
            guard let cpu = g.cpu, !g.incomplete, cpu >= threshold, let identity = g.main?.identity ?? g.rows.first?.identity else { return g }
            let began = beginnings[g.key].flatMap { $0.identity == identity ? $0.time : nil } ?? time
            keep[g.key] = (identity, began); g.sustained = max(0, time - began)
            return g
        }
        beginnings = keep; return result
    }
}
struct CleanupTarget {
    let name: String
    let row: ProcessRow
    let path: String
    let bundleID: String
    let beforeCPU: Double?
    let beforeMemory: UInt64
    init?(_ group: AppGroup) {
        guard group.canQuit, let row = group.main, let id = group.bundleID else { return nil }
        name = group.name; self.row = row; path = group.path; bundleID = id
        beforeCPU = group.cpu; beforeMemory = group.memory
    }
}
enum QuitOutcome { case requested, refused(String), gone }
func requestQuit(_ target: CleanupTarget, force: Bool) -> QuitOutcome {
    guard let live = ProcessRow.live(target.row.identity.pid) else { return .gone }
    guard Protection.same(target.row, live), Protection.allowed(live, appPath: target.path, bundleID: target.bundleID),
          let app = NSRunningApplication(processIdentifier: live.identity.pid),
          app.bundleURL?.path == target.path, app.bundleIdentifier == target.bundleID,
          !app.isTerminated else {
        return .refused("进程身份或权限已变化，请重新选择目标。")
    }
    let accepted = force ? app.forceTerminate() : app.terminate()
    return accepted ? .requested : .refused("应用没有接受退出请求，可能已退出或受系统限制。")
}
func targetStillRunning(_ target: CleanupTarget) -> Bool {
    guard let row = ProcessRow.live(target.row.identity.pid) else { return false }
    return Protection.same(target.row, row)
}
func networkEvidence(_ interfaces: [InterfaceSample]) -> String {
    let physical = interfaces.filter { $0.name.hasPrefix("en") }.compactMap(\.packetRate).reduce(0, +)
    if let suspicious = interfaces.first(where: { $0.name.hasPrefix("utun") && ($0.packetRate ?? 0) > 10_000 && ($0.packetRate ?? 0) > max(1, physical) * 10 }) {
        return "\(suspicious.name) 每秒约 \(Int(suspicious.packetRate ?? 0)) 包，远高于物理网卡；疑似重复处理，需进一步核实。"
    }
    let tun = interfaces.filter { $0.name.hasPrefix("utun") }
    guard let active = tun.filter({ $0.packetRate != nil }).max(by: { ($0.packetRate ?? 0) < ($1.packetRate ?? 0) }) else {
        return tun.isEmpty ? "当前没有 TUN 接口。" : "正在等待第二次网络采样。"
    }
    return "\(active.name) 约 \(Int(active.packetRate ?? 0)) 包 / 秒；物理网卡合计约 \(Int(physical)) 包 / 秒。未发现明显流量失衡。"
}
