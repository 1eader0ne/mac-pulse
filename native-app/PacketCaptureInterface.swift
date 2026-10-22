import AppKit
import UniformTypeIdentifiers

final class PacketCaptureTool: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(), table = NSTableView()
    let interface = NSPopUpButton(), preset = NSPopUpButton(), duration = NSPopUpButton(), snapshot = NSPopUpButton()
    let filter = NSTextField(string: "")
    let refreshButton = NSButton(title: "刷新网卡", target: nil, action: nil)
    let startButton = NSButton(title: "授权并开始抓包…", target: nil, action: nil)
    let stopButton = NSButton(title: "停止抓包", target: nil, action: nil)
    let exportButton = NSButton(title: "导出 PCAP…", target: nil, action: nil)
    let clearButton = NSButton(title: "清空", target: nil, action: nil)
    let summary = label("尚未抓包", size: 24, weight: .semibold)
    let status = label("选择网卡和过滤条件，再点击开始。系统可能要求管理员授权。", size: 12, color: .secondaryLabelColor)
    let detail = NSTextView()
    let clock: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "HH:mm:ss.SSS"; return value
    }()
    let queue = DispatchQueue(label: "com.hb.macpulse.packet.capture", qos: .utility)
    var packets: [CapturedPacket] = []
    private(set) var busy = false
    private(set) var exportable = false
    private(set) var job: PacketCaptureJob?
    // Injectable runner keeps UI verification off real network traffic and authorization dialogs.
    var runner: (PacketCaptureJob, @escaping (CaptureEvent) -> Void) -> Void = { $0.run(event: $1) }
    var cleanup: () -> CaptureCleanupReport = { CaptureTemporaryFiles.cleanup() }

    override init() {
        super.init()
        for (button, action) in [(refreshButton, #selector(refreshInterfaces)), (startButton, #selector(start)),
                                 (stopButton, #selector(stop)), (exportButton, #selector(exportPCAP)), (clearButton, #selector(clear))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        preset.addItems(withTitles: ["全部流量", "TCP", "UDP", "DNS", "HTTPS", "ICMP"])
        preset.target = self; preset.action = #selector(changePreset)
        duration.addItems(withTitles: ["15 秒", "30 秒", "60 秒", "120 秒"]); duration.selectItem(at: 1)
        snapshot.addItems(withTitles: ["256 字节 / 包", "1518 字节 / 包"])
        filter.placeholderString = "BPF 过滤，例如 host 192.168.1.1 and tcp port 443"
        filter.setAccessibilityLabel("抓包 BPF 过滤条件")
        interface.setAccessibilityLabel("抓包网络接口"); duration.setAccessibilityLabel("抓包最长时长")
        snapshot.setAccessibilityLabel("每包截取长度")
        filter.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        interface.widthAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true
        for (id, title, width) in [("time", "时间", 100.0), ("protocol", "协议", 65.0), ("source", "来源地址 / 端口", 210.0),
                                    ("destination", "目标地址 / 端口", 210.0), ("length", "原始长度", 75.0), ("summary", "摘要", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title
            column.width = width; column.minWidth = 50; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.style = .plain; table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        detail.isEditable = false; detail.isSelectable = true; detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.string = "选择一包查看地址、截取长度和十六进制数据。"; detail.textContainerInset = NSSize(width: 10, height: 8)
        let detailScroll = NSScrollView(); detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detailScroll.heightAnchor.constraint(equalToConstant: 135).isActive = true
        status.isSelectable = true; status.maximumNumberOfLines = 4
        fillTool(stack([
            stack([label("网络抓包", size: 26, weight: .bold), label("记录本机接口上的数据包，导出后可用 Wireshark 分析", size: 13, color: .secondaryLabelColor)], spacing: 5),
            inset(summary),
            stack([label("网卡", size: 12), interface, refreshButton, label("上限", size: 12), duration, snapshot, NSView(), stopButton, startButton], vertical: false, spacing: 8),
            stack([label("过滤", size: 12), filter, preset], vertical: false, spacing: 8),
            label("每次最多 5,000 包（文件约 8 MB 以内），到时自动停止；切换页签继续抓取，退出应用停止。en 通常为物理网卡，lo0 为本机回环，utun 为 VPN。", size: 11, color: .secondaryLabelColor),
            scroll, detailScroll,
            label("抓包可能包含域名、地址及明文内容，仅保存在本机临时目录。HTTPS / TLS 内容保持加密；导出或分享前请核对。", size: 11, color: accent),
            stack([status, NSView(), clearButton, exportButton], vertical: false)
        ], spacing: 12), in: view)
        refreshInterfaces(); update()
    }
    deinit { job?.stop() }
    func update() {
        for control: NSControl in [interface, preset, duration, snapshot, filter, refreshButton, startButton] { control.isEnabled = !busy }
        startButton.isEnabled = !busy && interface.numberOfItems > 0
        stopButton.isEnabled = busy; exportButton.isEnabled = !busy && exportable; clearButton.isEnabled = !busy && job != nil
    }
    @objc func refreshInterfaces() {
        guard !busy else { return }
        let previous = interface.titleOfSelectedItem
        interface.removeAllItems(); interface.addItems(withTitles: CaptureOptions.interfaces())
        if let previous = previous { interface.selectItem(withTitle: previous) }
        if interface.indexOfSelectedItem < 0, interface.numberOfItems > 0 { interface.selectItem(at: 0) }
        if interface.numberOfItems == 0 { status.stringValue = "未能读取网络接口，请连接网络后刷新。" }
        update()
    }
    @objc func changePreset() {
        guard !busy else { return }
        filter.stringValue = ["", "tcp", "udp", "port 53", "tcp port 443 or udp port 443", "icmp or icmp6"][preset.indexOfSelectedItem]
    }
    func cleanupStaleCaptures() {
        let clean = cleanup
        queue.async { [weak self] in
            let report = clean()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.busy, self.job == nil, let message = report.message else { return }
                self.status.stringValue = message
            }
        }
    }
    @objc func start() {
        guard !busy else { return }
        do {
            let options = try CaptureOptions(interface: interface.titleOfSelectedItem ?? "", filter: filter.stringValue,
                seconds: [15, 30, 60, 120][duration.indexOfSelectedItem], snapshot: [256, 1518][snapshot.indexOfSelectedItem])
            let task = try PacketCaptureJob(options: options)
            packets.removeAll(); table.reloadData(); exportable = false; job = task; busy = true
            detail.string = "等待数据包…"; summary.stringValue = "等待系统授权…"
            status.stringValue = "\(options.interface) · \(options.filter.isEmpty ? "全部流量" : options.filter) · 最长 \(options.seconds) 秒 / 5,000 包；可随时停止。"
            update()
            let run = runner
            let clean = cleanup
            queue.async { [weak self] in
                _ = clean()
                run(task) { event in DispatchQueue.main.async { [weak self] in self?.receive(event, task: task) } }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    func receive(_ event: CaptureEvent, task: PacketCaptureJob) {
        guard job === task else { return }
        switch event {
        case .started: summary.stringValue = "正在抓包 · 等待匹配流量"
        case .packets(let batch):
            packets.append(contentsOf: batch); summary.stringValue = "已捕获 \(packets.count) 包"
            let selected = table.selectedRow
            table.reloadData()
            if packets.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        case .finished(let message, let valid):
            busy = false; exportable = valid; summary.stringValue = valid ? "抓包结束 · \(packets.count) 包" : "抓包未完成"
            status.stringValue = message; update()
        }
    }
    @objc func stop() {
        guard busy else { return }
        job?.stop(); stopButton.isEnabled = false; status.stringValue = "正在停止并保存已捕获的数据包…"
    }
    func shutdown() {
        job?.stop()
        if let directory = job?.directory { try? FileManager.default.removeItem(at: directory) }
    }
    @objc func clear() {
        guard !busy else { return }
        job = nil; packets.removeAll(); exportable = false; table.reloadData(); summary.stringValue = "尚未抓包"
        detail.string = "选择一包查看地址、截取长度和十六进制数据。"; status.stringValue = "临时抓包记录已清空。"; update()
    }
    func export(to url: URL) throws {
        guard !busy, exportable, let job = job else { throw DiskError.message("请先结束一次抓包。") }
        try Data(contentsOf: job.file, options: .mappedIfSafe).write(to: url, options: .atomic)
    }
    @objc func exportPCAP() {
        guard !busy, exportable else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "轻诊-抓包.pcap"
        panel.allowedContentTypes = [UTType(filenameExtension: "pcap") ?? .data]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do { try self.export(to: url); self.status.stringValue = "已导出 \(url.lastPathComponent)；文件可能含敏感网络数据，分享前请核对。" }
            catch { self.status.stringValue = "导出失败：\(error.localizedDescription)" }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { packets.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard packets.indices.contains(row) else { return nil }; let packet = packets[row]
        let text: String
        switch column?.identifier.rawValue {
        case "time": text = clock.string(from: packet.timestamp)
        case "protocol": text = packet.protocolName
        case "source": text = packet.source
        case "destination": text = packet.destination
        case "length": text = String(packet.originalLength)
        default: text = packet.summary
        }
        let field = label(text, size: 11); field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle; field.toolTip = text
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if packets.indices.contains(table.selectedRow) { detail.string = packets[table.selectedRow].detail }
    }
}
