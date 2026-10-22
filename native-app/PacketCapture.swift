import Foundation
import Darwin

struct CaptureOptions {
    let interface: String
    let filter: String
    let seconds: Int
    let snapshot: Int
    static let packetLimit = 5_000

    init(interface: String, filter: String, seconds: Int = 30, snapshot: Int = 256) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard !interface.isEmpty, interface.utf8.count < 64,
              interface.unicodeScalars.allSatisfy({ allowed.contains($0) }), !interface.hasPrefix("-") else {
            throw DiskError.message("请选择有效的网络接口。")
        }
        let expression = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expression.utf8.count <= 512, !expression.hasPrefix("-"),
              !expression.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DiskError.message("BPF 过滤条件最长 512 字节，不可包含控制字符或以选项开头。")
        }
        guard [15, 30, 60, 120].contains(seconds), [256, 1518].contains(snapshot) else {
            throw DiskError.message("请选择支持的抓包时长和截取长度。")
        }
        self.interface = interface; self.filter = expression; self.seconds = seconds; self.snapshot = snapshot
    }

    static func interfaces() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var names = Set<String>(), cursor = first
        while let item = cursor {
            names.insert(String(cString: item.pointee.ifa_name)); cursor = item.pointee.ifa_next
        }
        return names.sorted { a, b in
            if a.hasPrefix("en") != b.hasPrefix("en") { return a.hasPrefix("en") }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    var arguments: [String] {
        ["-n", "-p", "-U", "-i", interface, "-s", String(snapshot), "-c", String(Self.packetLimit)]
    }
}

struct CapturedPacket {
    let number: Int
    let timestamp: Date
    let originalLength: Int
    let bytes: Data
    let protocolName: String
    let source: String
    let destination: String
    let summary: String

    init(number: Int, timestamp: Date, originalLength: Int, bytes: Data, linkType: UInt32) {
        self.number = number; self.timestamp = timestamp; self.originalLength = originalLength; self.bytes = bytes
        let b = [UInt8](bytes)
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func address(_ start: Int, _ ipv6: Bool) -> String {
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let data = Array(b[start..<(start + (ipv6 ? 16 : 4))])
            return data.withUnsafeBytes { raw in
                guard inet_ntop(ipv6 ? AF_INET6 : AF_INET, raw.baseAddress, &output, socklen_t(output.count)) != nil else { return "?" }
                return String(cString: output)
            }
        }
        var offset = 0, etherType = 0
        if linkType == 1, b.count >= 14 {
            offset = 14; etherType = u16(12)
            while [0x8100, 0x88a8].contains(etherType), b.count >= offset + 4 {
                etherType = u16(offset + 2); offset += 4
            }
        } else if [0, 108].contains(linkType), b.count >= 4 { offset = 4 }
        else if ![12, 101, 228, 229].contains(linkType) {
            protocolName = "链路 \(linkType)"; source = "—"; destination = "—"; summary = "可导出后使用 Wireshark 解析"; return
        }
        var proto: UInt8 = 0, transport = 0, src = "—", dst = "—", kind = "其他", note = ""
        var fragmented = false
        if etherType == 0x0806 {
            kind = "ARP"
            if b.count >= offset + 28, b[offset + 4] == 6, b[offset + 5] == 4 {
                src = address(offset + 14, false); dst = address(offset + 24, false)
                note = u16(offset + 6) == 1 ? "查询地址" : "地址响应"
            }
        } else if b.count > offset, b[offset] >> 4 == 4, (etherType == 0 || etherType == 0x0800), b.count >= offset + 20 {
            let header = Int(b[offset] & 15) * 4
            if header >= 20, b.count >= offset + header {
                src = address(offset + 12, false); dst = address(offset + 16, false)
                proto = b[offset + 9]; transport = offset + header; kind = "IPv4"
                fragmented = u16(offset + 6) & 0x1fff != 0
            }
        } else if b.count > offset, b[offset] >> 4 == 6, (etherType == 0 || etherType == 0x86dd), b.count >= offset + 40 {
            src = address(offset + 8, true); dst = address(offset + 24, true)
            proto = b[offset + 6]; transport = offset + 40; kind = "IPv6"
            // Walk bounded IPv6 extension chains, without interpreting fragments as ports.
            for _ in 0..<8 {
                guard [0, 43, 44, 51, 60].contains(proto), b.count >= transport + 8 else { break }
                let length = proto == 44 ? 8 : proto == 51 ? (Int(b[transport + 1]) + 2) * 4 : (Int(b[transport + 1]) + 1) * 8
                guard b.count >= transport + length else { break }
                if proto == 44 { fragmented = u16(transport + 2) & 0xfff8 != 0 }
                proto = b[transport]; transport += length
                if fragmented { break }
            }
        }
        if transport > 0 {
            if fragmented { note = "IP 分片" }
            else if [6, 17].contains(proto), b.count >= transport + 4 {
                kind = proto == 6 ? "TCP" : "UDP"
                src = src.contains(":") ? "[\(src)]:\(u16(transport))" : "\(src):\(u16(transport))"
                dst = dst.contains(":") ? "[\(dst)]:\(u16(transport + 2))" : "\(dst):\(u16(transport + 2))"
                if proto == 6, b.count >= transport + 14 {
                    let flags = b[transport + 13]
                    note = [(UInt8(2), "SYN"), (16, "ACK"), (1, "FIN"), (4, "RST"), (8, "PSH")]
                        .filter { flags & $0.0 != 0 }.map { $0.1 }.joined(separator: " ")
                } else if u16(transport) == 53 || u16(transport + 2) == 53 { note = "DNS 端口" }
            } else if proto == 1 || proto == 58 { kind = proto == 1 ? "ICMP" : "ICMPv6" }
        }
        protocolName = kind; source = src; destination = dst
        summary = note + (bytes.count < originalLength ? " · 已截取 \(bytes.count)/\(originalLength) 字节" : "")
    }

    var detail: String {
        let hex = stride(from: 0, to: bytes.count, by: 16).map { offset -> String in
            let part = bytes.dropFirst(offset).prefix(16)
            return String(format: "%04x  ", offset) + part.map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
        return "#\(number)  \(protocolName)  \(source) → \(destination)\n原始 \(originalLength) 字节 · 保存 \(bytes.count) 字节  \(summary)\n\n\(hex)"
    }
}

// Incremental classic-PCAP decoding: incomplete headers/records stay buffered until the next read.
struct PCAPStream {
    private var pending = Data()
    private var little = true, nano = false, header = false
    private(set) var linkType: UInt32 = 0
    private(set) var count = 0
    mutating func append(_ data: Data) throws -> [CapturedPacket] {
        pending.append(data)
        func word(_ offset: Int) -> UInt32 {
            let b = [UInt8](pending[offset..<(offset + 4)])
            return little ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 :
                UInt32(b[3]) | UInt32(b[2]) << 8 | UInt32(b[1]) << 16 | UInt32(b[0]) << 24
        }
        if !header {
            guard pending.count >= 24 else { return [] }
            let magic = Array(pending.prefix(4))
            guard [[0xd4, 0xc3, 0xb2, 0xa1], [0xa1, 0xb2, 0xc3, 0xd4],
                   [0x4d, 0x3c, 0xb2, 0xa1], [0xa1, 0xb2, 0x3c, 0x4d]].contains(magic) else {
                throw DiskError.message("抓包文件格式无法识别，预期为 PCAP。")
            }
            little = magic[0] == 0xd4 || magic[0] == 0x4d; nano = magic[0] == 0x4d || magic[3] == 0x4d
            guard word(16) > 0, word(16) <= 262144 else { throw DiskError.message("PCAP 截取长度无效。") }
            linkType = word(20) & 0xffff; header = true; pending = Data(pending.dropFirst(24))
        }
        var packets: [CapturedPacket] = [], offset = 0
        while pending.count - offset >= 16 {
            let length = Int(word(offset + 8)), original = Int(word(offset + 12))
            guard length <= 262144, length <= original else { throw DiskError.message("PCAP 数据包长度无效。") }
            guard pending.count - offset >= 16 + length else { break }
            guard count < CaptureOptions.packetLimit else { throw DiskError.message("抓包数量超过上限。") }
            count += 1
            let time = Double(word(offset)) + Double(word(offset + 4)) / (nano ? 1_000_000_000 : 1_000_000)
            packets.append(CapturedPacket(number: count, timestamp: Date(timeIntervalSince1970: time), originalLength: original,
                bytes: pending.subdata(in: (offset + 16)..<(offset + 16 + length)), linkType: linkType))
            offset += 16 + length
        }
        if offset > 0 { pending = Data(pending.dropFirst(offset)) }
        return packets
    }
    var complete: Bool { header && pending.isEmpty }
}

enum CaptureEvent {
    case started
    case packets([CapturedPacket])
    case finished(String, Bool)
}

final class PacketCaptureJob {
    let options: CaptureOptions
    let directory: URL
    var file: URL { directory.appendingPathComponent("capture.pcap") }
    var control: URL { directory.appendingPathComponent("active") }
    let cancellation = DiskCancellation()
    private var leaseFD: Int32 = -1

    init(options: CaptureOptions, temporaryRoot: URL = CaptureTemporaryFiles.root) throws {
        self.options = options
        directory = temporaryRoot.appendingPathComponent(CaptureTemporaryFiles.prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            leaseFD = try CaptureTemporaryFiles.createLease(in: directory)
            try Data().write(to: control, options: .withoutOverwriting)
        } catch {
            if leaseFD >= 0 { Darwin.close(leaseFD); leaseFD = -1 }
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        if leaseFD >= 0 { Darwin.close(leaseFD) }
    }
    func stop() { cancellation.cancel(); try? FileManager.default.removeItem(at: control) }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // The privileged shell only starts a system binary and supervises its own child.
    // tcpdump opens BPF, then -Z drops privilege BEFORE opening the user's output file.
    static func supervisedCommand(_ command: String, control: URL, seconds: Int) -> String {
        let marker = quote(control.path)
        return """
        [ -f \(marker) ] || exit 0
        \(command) 2>&1 &
        capture_pid=$!
        stop_capture() {
          if [ "$(jobs -pr)" = "$capture_pid" ]; then kill -INT "$capture_pid"; fi
          /bin/sleep 1
          if [ "$(jobs -pr)" = "$capture_pid" ]; then kill -TERM "$capture_pid"; fi
        }
        trap stop_capture EXIT
        trap 'stop_capture; exit 130' HUP INT TERM
        remaining=\(seconds)
        while [ "$remaining" -gt 0 ] && [ -f \(marker) ] && [ "$(jobs -pr)" = "$capture_pid" ]; do
          /bin/sleep 1
          remaining=$((remaining - 1))
        done
        stop_capture
        wait "$capture_pid"
        capture_status=$?
        trap - EXIT HUP INT TERM
        exit "$capture_status"
        """
    }
    var command: String {
        let args = options.arguments + ["-Z", NSUserName(), "-w", file.path] + (options.filter.isEmpty ? [] : [options.filter])
        return Self.supervisedCommand((["/usr/sbin/tcpdump"] + args).map(Self.quote).joined(separator: " "), control: control, seconds: options.seconds)
    }
    static func privilegedProcess(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv\nwith timeout of 180 seconds\ndo shell script (item 1 of argv) with administrator privileges\nend timeout\nend run", command]
        return process
    }
    func run(launcher: (String) -> Process = PacketCaptureJob.privilegedProcess, event: @escaping (CaptureEvent) -> Void) {
        defer { try? FileManager.default.removeItem(at: control) }
        let process = launcher(command), output = Pipe()
        process.standardOutput = output; process.standardError = output
        var reader: FileHandle?, stream = PCAPStream(), errorMessage: String?, stopTime: Date?
        defer { try? reader?.close() }
        do {
            guard !cancellation.cancelled else { event(.finished("已取消抓包", false)); return }
            try process.run()
            func read() throws {
                if reader == nil, FileManager.default.fileExists(atPath: file.path) {
                    reader = try FileHandle(forReadingFrom: file); event(.started)
                }
                if let reader = reader {
                    let data = try reader.read(upToCount: 1_048_576) ?? Data()
                    let packets = try stream.append(data)
                    if !packets.isEmpty { event(.packets(packets)) }
                }
            }
            while process.isRunning {
                do { try read() } catch { errorMessage = error.localizedDescription; stop() }
                if cancellation.cancelled {
                    try? FileManager.default.removeItem(at: control)
                    if stopTime == nil { stopTime = Date() }
                    // Also dismiss a still-pending authorization request; the marker prevents a late start.
                    if Date().timeIntervalSince(stopTime!) > 3 { process.terminate() }
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            process.waitUntilExit()
            // Drain remaining complete records after tcpdump has flushed and closed the file.
            try read()
            if let reader = reader {
                while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
                    let packets = try stream.append(data); if !packets.isEmpty { event(.packets(packets)) }
                }
            }
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = stream.complete
            if let errorMessage = errorMessage { event(.finished("抓包读取失败：\(errorMessage)", false)) }
            else if !valid {
                let hint = message.contains("-128") ? "已取消系统授权。" : message.isEmpty ? "未生成完整抓包文件。" : String(message.prefix(1400))
                event(.finished(cancellation.cancelled ? "已取消抓包" : "未能开始抓包：\(hint)", false))
            } else {
                let reason = cancellation.cancelled ? "已停止" : process.terminationStatus == 0 ? "本次抓包结束" : "抓包已结束（可能达到时限或接口中断）"
                event(.finished("\(reason) · \(stream.count) 包\n\(String(message.suffix(1800)))", true))
            }
        } catch { stop(); event(.finished("抓包失败：\(error.localizedDescription)", false)) }
    }
}
