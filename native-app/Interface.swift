import AppKit
import UniformTypeIdentifiers

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    return field
}
func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
    s.alignment = vertical ? .leading : .centerY; s.spacing = spacing
    return s
}
func inset(_ content: NSView, amount: CGFloat = 18) -> NSView {
    let box = NSView(); box.wantsLayer = true
    box.layer?.backgroundColor = NSColor.white.cgColor
    box.layer?.cornerRadius = 14; box.layer?.borderWidth = 1
    box.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
    box.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: amount),
        content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -amount),
        content.topAnchor.constraint(equalTo: box.topAnchor, constant: amount),
        content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -amount)
    ]); return box
}
final class Sparkline: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let path = NSBezierPath()
        for (i, value) in values.enumerated() {
            let p = NSPoint(x: CGFloat(i) / CGFloat(values.count - 1) * bounds.width,
                            y: 2 + CGFloat(min(100, max(0, value))) / 100 * (bounds.height - 4))
            i == 0 ? path.move(to: p) : path.line(to: p)
        }
        accent.setStroke(); path.lineWidth = 2; path.lineJoinStyle = .round; path.stroke()
    }
}
final class MetricCard: NSView {
    let value = label("等待采样", size: 26, weight: .semibold)
    let detail = label("", size: 11, color: .secondaryLabelColor)
    let graph = Sparkline()
    init(_ title: String, symbol: String) {
        super.init(frame: .zero)
        let heading = label(title, size: 12, weight: .medium, color: .secondaryLabelColor)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.contentTintColor = accent
        let spacer = NSView()
        let header = stack([heading, spacer, icon], vertical: false)
        let content = stack([header, value, detail, graph], spacing: 7)
        let card = inset(content)
        addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     header.widthAnchor.constraint(equalTo: content.widthAnchor), graph.widthAnchor.constraint(equalTo: content.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    let moduleHost = NSView()
    let diagnosticsView = NSView()
    var diskTool = DiskTool()
    var duplicateTool = DuplicateTool()
    var networkTool = NetworkTool()
    var uninstallTool = UninstallTool()
    let modules = NSSegmentedControl(labels: ["运行诊断", "磁盘空间", "重复文件", "网络健康", "应用卸载"], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    let cpuCard = MetricCard("整机 CPU", symbol: "cpu")
    let memoryCard = MetricCard("内存概况", symbol: "memorychip")
    let networkCard = MetricCard("虚拟网卡", symbol: "network")
    let search = NSSearchField()
    let filters = NSSegmentedControl(labels: ["全部进程", "持续高占用", "可退出应用"], trackingMode: .selectOne, target: nil, action: nil)
    let threshold = NSPopUpButton()
    let pause = NSButton()
    let footer = label("正在读取本机状态…", size: 11, color: .secondaryLabelColor)
    let detailTitle = label("选择一个应用", size: 21, weight: .semibold)
    let detailSubtitle = label("查看占用证据与清理选项", size: 12, color: .secondaryLabelColor)
    let evidence = label("", size: 12)
    let pathLabel = label("", size: 10, color: .secondaryLabelColor)
    let processDetails = label("", size: 11, color: .secondaryLabelColor)
    let history = label("清理记录会显示在这里。", size: 11, color: .secondaryLabelColor)
    let notice = label("", size: 12, color: accent)
    let quitButton = NSButton(title: "正常退出应用", target: nil, action: nil)
    let forceButton = NSButton(title: "强制结束…", target: nil, action: nil)
    let detector = Detector()
    let queue = DispatchQueue(label: "com.hb.macpulse.sampler", qos: .utility)
    var timer: Timer?
    var busy = false
    var paused = false
    var snapshot: Snapshot?
    var allGroups: [AppGroup] = []
    var visible: [AppGroup] = []
    var icons: [String: NSImage] = [:]
    var records: [String] = []
    var selectedKey: String?
    var thresholdValue: Double { Double(threshold.titleOfSelectedItem?.replacingOccurrences(of: "%", with: "") ?? "80") ?? 80 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 810),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "轻诊 1.4.0 · Mac 工具盒"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        window.minSize = NSSize(width: 1100, height: 840)
        window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        window.setContentSize(NSSize(width: 1160, height: 860))
        window.center(); constructToolbox(); constructInterface()
        if CommandLine.arguments.contains("--disk") { modules.selectedSegment = 1; switchModule() }
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "关于轻诊", action: #selector(about), keyEquivalent: "")
        submenu.addItem(.separator()); submenu.addItem(withTitle: "退出轻诊", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        let editItem = NSMenuItem(); menu.addItem(editItem); editItem.submenu = NSMenu(title: "编辑")
        editItem.submenu?.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }
    func constructToolbox() {
        guard let content = window.contentView else { return }
        modules.selectedSegment = 0; modules.target = self; modules.action = #selector(switchModule)
        let navigation = stack([label("轻诊工具盒", size: 14, weight: .semibold), modules, NSView(),
                                label("1.4.0 · 原生 Mac 工具", size: 11, color: .secondaryLabelColor)], vertical: false, spacing: 20)
        let root = stack([navigation, moduleHost], spacing: 18)
        content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                                     navigation.widthAnchor.constraint(equalTo: root.widthAnchor), moduleHost.widthAnchor.constraint(equalTo: root.widthAnchor)])
        for child in [diagnosticsView, diskTool.view, duplicateTool.view, networkTool.view, uninstallTool.view] {
            moduleHost.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: moduleHost.leadingAnchor), child.trailingAnchor.constraint(equalTo: moduleHost.trailingAnchor),
                                         child.topAnchor.constraint(equalTo: moduleHost.topAnchor), child.bottomAnchor.constraint(equalTo: moduleHost.bottomAnchor)])
        }
        switchModule()
    }
    @objc func switchModule() {
        diagnosticsView.isHidden = modules.selectedSegment != 0
        diskTool.view.isHidden = modules.selectedSegment != 1
        duplicateTool.view.isHidden = modules.selectedSegment != 2
        networkTool.view.isHidden = modules.selectedSegment != 3
        uninstallTool.view.isHidden = modules.selectedSegment != 4
        if modules.selectedSegment == 4 { uninstallTool.ensureLoaded() }
        if modules.selectedSegment == 1 { diskTool.refreshCapacity() }
    }
    func constructInterface() {
        let title = stack([label("轻诊", size: 28, weight: .bold), label("看清负载，让 Mac 轻下来", size: 13, color: .secondaryLabelColor)], spacing: 5)
        let refresh = NSButton(title: "立即检查", target: self, action: #selector(refreshNow)); refresh.bezelStyle = .rounded
        pause.title = "暂停监测"; pause.target = self; pause.action = #selector(togglePause); pause.bezelStyle = .rounded
        let header = stack([title, NSView(), pause, refresh], vertical: false)
        let cards = stack([cpuCard, memoryCard, networkCard], vertical: false, spacing: 14)
        cards.distribution = .fillEqually
        filters.selectedSegment = 0; filters.target = self; filters.action = #selector(filterChanged)
        search.placeholderString = "搜索应用、进程或 PID"; search.delegate = self
        threshold.addItems(withTitles: ["30%", "50%", "80%", "100%", "150%"])
        let saved = UserDefaults.standard.string(forKey: "threshold") ?? "80%"
        threshold.selectItem(withTitle: saved); threshold.target = self; threshold.action = #selector(thresholdChanged)
        let controls = stack([filters, NSView(), search], vertical: false)
        let hint = stack([label("持续阈值", size: 11, color: .secondaryLabelColor), threshold,
                          label("超过阈值满 15 秒才标记；进程 CPU 按单核计算，可超过 100%。", size: 11, color: .secondaryLabelColor)], vertical: false, spacing: 7)
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for (id, name, width) in [("app", "应用 / 进程", 220.0), ("cpu", "CPU", 90.0), ("memory", "内存 RSS", 100.0), ("state", "状态", 115.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name; column.width = width
            column.minWidth = id == "app" ? 160 : 75
            column.resizingMask = id == "app" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 46
        table.usesAlternatingRowBackgroundColors = true; table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let tablePanel = stack([controls, hint, scroll], spacing: 9)
        controls.widthAnchor.constraint(equalTo: tablePanel.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: tablePanel.widthAnchor).isActive = true
        quitButton.target = self; quitButton.action = #selector(normalQuit); quitButton.bezelStyle = .rounded
        forceButton.target = self; forceButton.action = #selector(forceQuit); forceButton.bezelStyle = .rounded
        forceButton.contentTintColor = .systemRed
        quitButton.isEnabled = false; forceButton.isEnabled = false
        evidence.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        pathLabel.isSelectable = true; pathLabel.lineBreakMode = .byCharWrapping
        let sideContent = stack([detailTitle, detailSubtitle, evidence, pathLabel, processDetails, quitButton, forceButton,
                                 label("清理会保留软件安装与文件。强制结束可能丢失未保存内容。", size: 11, color: .secondaryLabelColor),
                                 notice, NSView(), label("最近清理", size: 12, weight: .semibold), history], spacing: 12)
        let sideScroll = NSScrollView(); sideScroll.hasVerticalScroller = true; sideScroll.drawsBackground = false
        sideScroll.documentView = sideContent; sideContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sideContent.leadingAnchor.constraint(equalTo: sideScroll.contentView.leadingAnchor),
                                     sideContent.trailingAnchor.constraint(equalTo: sideScroll.contentView.trailingAnchor),
                                     sideContent.topAnchor.constraint(equalTo: sideScroll.contentView.topAnchor)])
        let side = inset(sideScroll); side.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let body = stack([tablePanel, side], vertical: false, spacing: 16); body.alignment = .top
        side.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        tablePanel.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let export = NSButton(title: "导出诊断报告…", target: self, action: #selector(exportReport)); export.bezelStyle = .rounded
        let bottom = stack([footer, NSView(), export], vertical: false)
        let root = stack([header, cards, body, bottom], spacing: 18)
        let content = diagnosticsView
        content.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     root.topAnchor.constraint(equalTo: content.topAnchor),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for view in [header, cards, body, bottom] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        cards.heightAnchor.constraint(equalToConstant: 146).isActive = true
    }
    func sample(force: Bool = false, completion: (() -> Void)? = nil) {
        if busy {
            if completion != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sample(force: force, completion: completion) } }
            return
        }
        guard !paused || force else { return }
        busy = true
        let previous = snapshot
        queue.async { [weak self] in
            let result = measured(Snapshot.capture(), after: previous)
            DispatchQueue.main.async { self?.receive(result); completion?() }
        }
    }
    func receive(_ result: Snapshot) {
        busy = false; snapshot = result
        allGroups = detector.update(groups(result.rows, applications: NSWorkspace.shared.runningApplications), time: result.time, threshold: thresholdValue)
        applyFilter()
        if let cpu = result.totalCPU {
            cpuCard.value.stringValue = String(format: "%.1f%%", cpu)
            cpuCard.graph.values = Array((cpuCard.graph.values + [cpu]).suffix(60))
        } else { cpuCard.value.stringValue = "等待第二次采样" }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "热压力正常"
        case .fair: thermal = "热压力略高"
        case .serious: thermal = "热压力较高"
        case .critical: thermal = "热压力严重"
        @unknown default: thermal = "热状态不可用"
        }
        cpuCard.detail.stringValue = "\(ProcessInfo.processInfo.activeProcessorCount) 核 · \(thermal) · 非温度读数"
        memoryCard.value.stringValue = result.system.memory_valid != 0 ? byteText(result.system.physical) : "读取受限"
        let pressure = [1: "正常", 2: "警告", 4: "严重"][Int(result.system.pressure)] ?? "未知"
        memoryCard.detail.stringValue = "压缩 \(byteText(result.system.compressed)) · 交换 \(byteText(result.system.swap_used)) · 压力\(pressure)"
        let tun = result.interfaces.filter { $0.name.hasPrefix("utun") }
        let netRate = tun.compactMap(\.packetRate)
        networkCard.value.stringValue = netRate.isEmpty ? "等待速率" : "\(Int(netRate.reduce(0, +))) 包 / 秒"
        networkCard.detail.stringValue = "\(tun.count) 个 TUN 接口 · 点击应用可查看网络证据"
        let cpuMissing = result.rows.filter { !$0.readable }.count
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        footer.stringValue = "\(paused ? "已暂停" : "每 2 秒采样") · \(formatter.string(from: Date())) · \(result.rows.count) 个进程 · \(result.rows.filter { $0.smoothed }.count) 个系统平滑读数 · \(cpuMissing) 个受限 · \(Int(result.duration * 1000)) ms\(result.truncated ? " · 已截断" : "")"
        if result.rows.isEmpty { footer.stringValue = "无法读取进程。请从 Finder 打开应用后重试；未执行任何清理。" }
        updateDetails()
    }
    func applyFilter() {
        let query = search.stringValue.lowercased()
        visible = allGroups.filter { g in
            let matches = query.isEmpty || g.name.lowercased().contains(query) || g.rows.contains { String($0.identity.pid).contains(query) || $0.name.lowercased().contains(query) }
            let type = filters.selectedSegment
            return matches && (type == 0 || (type == 1 && g.sustained >= 15) || (type == 2 && g.canQuit))
        }.sorted { a, b in
            if (a.sustained >= 15) != (b.sustained >= 15) { return a.sustained >= 15 }
            if a.cpu != b.cpu { return (a.cpu ?? -1) > (b.cpu ?? -1) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        table.reloadData()
        if let key = selectedKey, let index = visible.firstIndex(where: { $0.key == key }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count, let id = column?.identifier.rawValue else { return nil }
        let g = visible[row]
        let text: String
        switch id {
        case "cpu": text = g.cpu.map { String(format: "%.1f%%%@", $0, g.incomplete ? " *" : g.rows.contains(where: { $0.smoothed }) ? " ~" : "") } ?? "不可用"
        case "memory": text = g.rows.contains(where: { $0.readable }) ? byteText(g.memory) : "不可用"
        case "state": text = g.sustained >= 15 ? "持续高占用" : (g.cpu ?? 0) >= thresholdValue ? "观察中" : g.canQuit ? "可退出" : "受保护"
        default: text = g.name
        }
        let cell = NSTableCellView(); let field = label(text, size: 12, weight: id == "cpu" ? .semibold : .regular)
        field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingTail
        if id == "state", g.sustained >= 15 { field.textColor = .systemRed }
        if id == "cpu", (g.cpu ?? 0) >= thresholdValue { field.textColor = accent }
        cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
        var offset: CGFloat = 9
        if id == "app" {
            let image: NSImage
            if let cached = icons[g.key] { image = cached }
            else {
                image = g.path.contains(".app") ? NSWorkspace.shared.icon(forFile: g.path) : NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "进程") ?? NSImage()
                // Cache applications only; short-lived process identities must not accumulate.
                if g.path.contains(".app") { icons[g.key] = image }
            }
            let icon = NSImageView(image: image); cell.addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 25), icon.heightAnchor.constraint(equalToConstant: 25)])
            offset = 42
        }
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: offset),
                                     field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 && table.selectedRow < visible.count { selectedKey = visible[table.selectedRow].key }
        updateDetails()
    }
    var selected: AppGroup? { allGroups.first { $0.key == selectedKey } }
    func updateDetails() {
        guard let g = selected else {
            detailTitle.stringValue = selectedKey == nil ? "选择一个应用" : "目标已退出"
            detailSubtitle.stringValue = "点击列表查看占用证据"
            evidence.stringValue = snapshot.map { networkEvidence($0.interfaces) } ?? "正在读取本机状态…"
            pathLabel.stringValue = ""; processDetails.stringValue = ""
            quitButton.isEnabled = false; forceButton.isEnabled = false; return
        }
        detailTitle.stringValue = g.name
        detailSubtitle.stringValue = "\(g.rows.count) 个进程 · RSS \(byteText(g.memory))"
        let cpu = g.cpu.map { String(format: "%.1f%%", $0) } ?? "不可用"
        let duration = g.sustained >= 15 ? "超过 \(Int(thresholdValue))% 已持续 \(Int(g.sustained)) 秒。高占用不一定代表故障。" : "持续高占用尚未达到 15 秒判定窗口。"
        evidence.stringValue = "当前 CPU \(cpu)\(g.incomplete ? "（部分进程数据缺失）" : "")\(g.rows.contains(where: { $0.smoothed }) ? "\n~ 表示系统 ps 的平滑读数，非两秒瞬时值。" : "")\n\n\(duration)\n\n\(snapshot.map { networkEvidence($0.interfaces) } ?? "")"
        pathLabel.stringValue = g.path.isEmpty ? "进程路径不可用" : g.path
        processDetails.stringValue = g.rows.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(5).map {
            "PID \($0.identity.pid) · \($0.name) · \($0.cpu.map { String(format: "%.1f%%", $0) } ?? "不可用")"
        }.joined(separator: "\n")
        quitButton.isEnabled = g.canQuit; forceButton.isEnabled = g.canQuit
        if !g.canQuit { processDetails.stringValue += "\n\n系统服务、其他用户、工具自身和未注册为应用的进程受到保护。" }
    }
    @objc func filterChanged() { applyFilter(); updateDetails() }
    func controlTextDidChange(_ obj: Notification) { filterChanged() }
    @objc func thresholdChanged() {
        UserDefaults.standard.set(threshold.titleOfSelectedItem, forKey: "threshold"); detector.reset(); sample(force: true)
    }
    @objc func refreshNow() { sample(force: true) }
    @objc func togglePause() {
        paused.toggle(); pause.title = paused ? "恢复监测" : "暂停监测"
        detector.reset()
        if !paused { snapshot = nil; sample() } else { footer.stringValue = "已暂停监测。可点击立即检查获取一次采样。" }
    }
    @objc func normalQuit() { confirmQuit(force: false) }
    @objc func forceQuit() { confirmQuit(force: true) }
    func confirmQuit(force: Bool) {
        guard let group = selected, let target = CleanupTarget(group) else { return }
        let alert = NSAlert(); alert.alertStyle = force ? .warning : .informational
        alert.messageText = force ? "强制结束「\(target.name)」？" : "退出「\(target.name)」？"
        alert.informativeText = "目标 PID \(target.row.identity.pid)\n\(target.path)\n\n" + (force ? "强制结束可能丢失未保存内容。软件安装与文件会保留。" : "先请求应用正常退出；如有未保存内容，应用可能提示保存或拒绝退出。")
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: force ? "强制结束" : "正常退出")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.performQuit(target, force: force)
        }
    }
    func performQuit(_ target: CleanupTarget, force: Bool) {
        switch requestQuit(target, force: force) {
        case .gone: notice.stringValue = "应用已退出，无需再次清理。"; sample(force: true)
        case .refused(let message): notice.stringValue = message
        case .requested:
            notice.stringValue = "请求已发出，正在核对退出结果…"
            checkQuit(target, force: force, attempt: 0)
        }
    }
    func checkQuit(_ target: CleanupTarget, force: Bool, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            if targetStillRunning(target) {
                if attempt < 7 { self.checkQuit(target, force: force, attempt: attempt + 1) }
                else { self.notice.stringValue = "应用仍在运行。请检查保存提示；正常退出不会自动升级为强制结束。" }
            } else {
                self.sample(force: true)
                // Wait for two measurements so newly-created PIDs have measurable CPU.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self = self else { return }
                    self.sample(force: true) { [weak self] in
                    guard let self = self else { return }
                    let current = self.allGroups.first { $0.path == target.path }
                    let remaining = current?.rows.count ?? 0
                    let nowCPU = current?.cpu.map { String(format: "%.1f%%", $0) } ?? (remaining == 0 ? "0%" : "不可用")
                    let before = target.beforeCPU.map { String(format: "%.1f%%", $0) } ?? "不可用"
                    let text = "\(target.name) · \(force ? "强制结束" : "正常退出")\nCPU \(before) → \(nowCPU)\nRSS \(byteText(target.beforeMemory)) → \(byteText(current?.memory ?? 0))\n剩余同应用进程 \(remaining)\(remaining > 0 ? "，可能有残留或已重新启动" : "")"
                    self.notice.stringValue = remaining == 0 ? "已核实应用进程退出。" : "主进程已退出，仍检测到同应用进程。"
                    self.records.insert(text, at: 0); self.records = Array(self.records.prefix(20))
                    self.history.stringValue = self.records.prefix(2).joined(separator: "\n\n")
                    }
                }
            }
        }
    }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "轻诊 1.4.0 · Mac 工具盒"
        alert.informativeText = "Swift + AppKit 原生 Mac 工具。所有采样和诊断均在本机进行。高占用表示值得检查，不等于软件故障。"
        alert.runModal()
    }
    @objc func exportReport() {
        guard let sample = snapshot else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "轻诊-诊断报告.json"; panel.allowedContentTypes = [.json]
        let payload: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "cpuBasis": "100% = one logical core; systemCPU = all cores",
                                    "systemCPUPercent": sample.totalCPU as Any? ?? NSNull(), "networkEvidence": networkEvidence(sample.interfaces),
                                    "physicalMemoryBytes": sample.system.physical, "compressedMemoryBytes": sample.system.compressed, "swapUsedBytes": sample.system.swap_used,
                                    "interfaces": sample.interfaces.map { ["name": $0.name, "packetsPerSecond": $0.packetRate as Any? ?? NSNull(), "bytesPerSecond": $0.byteRate as Any? ?? NSNull()] as [String: Any] },
                                    "applications": allGroups.map { g -> [String: Any] in
                                        ["name": g.name, "path": g.path, "cpuPercent": g.cpu as Any? ?? NSNull(), "rssBytes": g.memory,
                                         "partialData": g.incomplete, "usesSmoothedSystemCPU": g.rows.contains(where: { $0.smoothed }), "highCPUDurationSeconds": g.sustained, "protected": !g.canQuit,
                                         "pids": g.rows.map { $0.identity.pid }]
                                    }, "cleanupHistory": records]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                self?.notice.stringValue = "报告已导出，可能包含应用名称和本机路径。"
            } catch { self?.notice.stringValue = "导出失败：\(error.localizedDescription)" }
        }
    }
    func renderPreview(to path: String) throws {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { networkTool.capture.shutdown() }
}
