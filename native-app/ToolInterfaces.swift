import AppKit

func toolMessage(_ title: String, _ text: String) {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
}
func toolReport(_ title: String, _ text: String) {
    let alert = NSAlert(); alert.messageText = title
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 360)); scroll.hasVerticalScroller = true
    let body = NSTextView(frame: scroll.bounds); body.string = text; body.isEditable = false
    body.font = .systemFont(ofSize: 12); body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
    scroll.documentView = body; alert.accessoryView = scroll; alert.addButton(withTitle: "关闭"); alert.runModal()
}
func fillTool(_ root: NSStackView, in view: NSView) {
    view.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
}
struct DuplicateRow {
    let group: Int
    let file: DuplicateEntry
    let keeper: Bool
}
final class DuplicateTool: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(), table = NSTableView()
    let folderButton = NSButton(title: "选择文件夹…", target: nil, action: nil)
    let scanButton = NSButton(title: "查找重复", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消查找", target: nil, action: nil)
    let selectButton = NSButton(title: "选择多余副本", target: nil, action: nil)
    let cleanButton = NSButton(title: "移入废纸篓…", target: nil, action: nil)
    let summary = label("尚未查找", size: 24, weight: .semibold)
    let folderLabel = label("请选择当前用户的个人文件夹。", size: 11, color: .secondaryLabelColor)
    let status = label("先按大小筛选，再以 SHA-256 和逐字节比较确认内容。", size: 12, color: .secondaryLabelColor)
    let selectionLabel = label("未选择副本", size: 12)
    let detail = label("每组按路径顺序保留第一份；保留项无法勾选。", size: 11, color: .secondaryLabelColor)
    let queue = DispatchQueue(label: "com.hb.macpulse.duplicates", qos: .utility)
    let home: URL
    var scope: DiskScope?
    private var panelFolder: URL?
    var result = DuplicateResult()
    var rows: [DuplicateRow] = []
    var selected = Set<String>()
    var busy = false
    var cancellation: DiskCancellation?
    var report = "尚无查找记录。"
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home; super.init()
        for (button, action) in [(folderButton, #selector(chooseFolder)), (scanButton, #selector(scan)), (cancelButton, #selector(cancel)),
                                  (selectButton, #selector(selectCopies)), (cleanButton, #selector(clean))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        let top = stack([label("重复文件", size: 26, weight: .bold),
            label("名称可以不同，内容必须相同；先确认用途，再处理副本。", size: 13, color: .secondaryLabelColor)], spacing: 5)
        let controls = stack([folderButton, scanButton, cancelButton, NSView(),
            NSButton(title: "文件夹权限…", target: self, action: #selector(openPermissions))], vertical: false)
        for (id, title, width) in [("check", "选择", 85.0), ("group", "分组", 70.0), ("file", "文件 / 路径", 580.0), ("size", "文件大小", 110.0), ("state", "处理", 110.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width
            col.minWidth = id == "file" ? 260 : width; col.resizingMask = id == "file" ? .autoresizingMask : []
            table.addTableColumn(col)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 52; table.style = .plain
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        folderLabel.isSelectable = true; folderLabel.lineBreakMode = .byTruncatingMiddle
        detail.isSelectable = true; detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingMiddle
        let details = stack([detail, NSView(), NSButton(title: "在 Finder 中显示", target: self, action: #selector(reveal))], vertical: false)
        let bottom = stack([selectButton, selectionLabel, NSView(), cleanButton], vertical: false)
        fillTool(stack([top, inset(summary), controls, folderLabel,
            label("只扫描非空普通文件；跳过链接、硬链接、隐藏目录、文件包、云端占位及带资源叉的文件。读取文件内容仅用于本机校验，不上传。", size: 11, color: .secondaryLabelColor),
            scroll, details, bottom,
            label("每组至少保留第一份，默认不勾选。相同内容不代表副本无用；清理前请关闭正在编辑这些文件的应用。仅移入废纸篓，不自动清空。", size: 11, color: accent),
            stack([status, NSView(), NSButton(title: "查看详情", target: self, action: #selector(showReport))], vertical: false)], spacing: 14), in: view)
        update()
    }
    deinit { cancellation?.cancel(); panelFolder?.stopAccessingSecurityScopedResource() }
    func useFolder(_ url: URL) throws {
        guard !busy else { throw DiskError.message("请先等待查找结束。") }
        scope = try DiskScope(root: url, kind: .large, home: home)
        result = DuplicateResult(); rows = []; selected = []; report = "尚无查找记录。"
        summary.stringValue = "尚未查找"; folderLabel.stringValue = "扫描范围：\(url.path)"
        status.stringValue = "点击查找重复；最多检查 50,000 项 / 120 秒 / 读取 20 GiB，达到上限会显示部分结果。"
        detail.stringValue = "每组按路径顺序保留第一份；保留项无法勾选。"
        table.reloadData(); update()
    }
    @objc func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择个人文件夹；查找会读取文件内容作本机比对，不上传。"; panel.prompt = "选择并查找"
        panel.directoryURL = scope?.root ?? home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try useFolder(url); panelFolder?.stopAccessingSecurityScopedResource(); panelFolder = url; scan()
        } catch { url.stopAccessingSecurityScopedResource(); toolMessage("无法扫描此目录", error.localizedDescription) }
    }
    @objc func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
    @objc func scan() {
        guard !busy, let scope = scope else { return }
        selected = []; rows = []; result = DuplicateResult(); table.reloadData()
        busy = true; let token = DiskCancellation(); cancellation = token; update()
        summary.stringValue = "查找中…"; status.stringValue = "按大小筛选…"
        detail.stringValue = "每组按路径顺序保留第一份；保留项无法勾选。"
        queue.async { [weak self] in
            let result = DuplicateScanner.find(scope, cancellation: token, progress: { text in
                DispatchQueue.main.async { [weak self] in self?.status.stringValue = text }
            })
            DispatchQueue.main.async { self?.receive(result) }
        }
    }
    func receive(_ outcome: DuplicateResult) {
        result = outcome; selected = []; busy = false; cancellation = nil
        rows = outcome.groups.enumerated().flatMap { index, group in
            group.files.enumerated().map { DuplicateRow(group: index + 1, file: $0.element, keeper: $0.offset == 0) }
        }
        summary.stringValue = outcome.rootFailure ? "目录读取失败" : "\(outcome.groups.count) 组 · \(outcome.redundant.count) 个多余副本"
        status.stringValue = outcome.status + " 检查 \(outcome.inspected) 项，读取 \(byteText(outcome.bytesRead))。"
        report = "\(scope?.root.path ?? "")\n\(status.stringValue)\n\n" + outcome.errors.joined(separator: "\n") +
            "\n\n仅比较普通数据内容，不比较标签和权限；带资源叉文件已排除。副本的实际释放空间受 APFS 克隆 / 快照影响。"
        table.reloadData(); update()
    }
    @objc func cancel() { cancellation?.cancel(); cancelButton.isEnabled = false; status.stringValue = "正在停止，等待当前文件操作返回…" }
    func update() {
        let allowed = Set(result.redundant.map { $0.url.path }); selected.formIntersection(allowed)
        folderButton.isEnabled = !busy; scanButton.isEnabled = !busy && scope != nil
        cancelButton.isEnabled = busy && cancellation != nil; selectButton.isEnabled = !busy && !allowed.isEmpty
        cleanButton.isEnabled = !busy && !selected.isEmpty
        selectButton.title = selected.isEmpty ? "选择多余副本" : "取消选择"
        let files = result.redundant.filter { selected.contains($0.url.path) }
        selectionLabel.stringValue = "已选 \(files.count) 个副本 · 估算占用 \(byteText(files.reduce(0) { $0 + $1.allocated }))"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        switch column?.identifier.rawValue {
        case "check":
            let button = NSButton(checkboxWithTitle: item.keeper ? "保留" : "", target: self, action: #selector(toggle(_:)))
            button.tag = row; button.state = selected.contains(item.file.url.path) ? .on : .off; button.isEnabled = !busy && !item.keeper
            button.setAccessibilityLabel("\(item.keeper ? "保留" : "选择副本") \(item.file.url.lastPathComponent)"); return button
        case "group": return label("第 \(item.group) 组", size: 12)
        case "file":
            let name = label(item.file.url.lastPathComponent, size: 12, weight: .medium)
            let path = label(item.file.url.deletingLastPathComponent().path, size: 10, color: .secondaryLabelColor)
            for field in [name, path] { field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle }
            let cell = stack([name, path], spacing: 3); cell.toolTip = item.file.url.path; return cell
        case "size": return label(byteText(item.file.size), size: 12)
        default: return label(item.keeper ? "保留第一份" : "内容已核对", size: 11, color: item.keeper ? accent : .secondaryLabelColor)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if rows.indices.contains(table.selectedRow) { detail.stringValue = rows[table.selectedRow].file.url.path }
    }
    @objc func toggle(_ sender: NSButton) {
        guard !busy, rows.indices.contains(sender.tag), !rows[sender.tag].keeper else { return }
        let path = rows[sender.tag].file.url.path
        if selected.contains(path) { selected.remove(path) } else if selected.count < 1000 { selected.insert(path) }
        update(); table.reloadData()
    }
    @objc func selectCopies() {
        guard !busy else { return }
        selected = selected.isEmpty ? Set(result.redundant.prefix(1000).map { $0.url.path }) : []
        update(); table.reloadData()
    }
    @objc func reveal() {
        guard rows.indices.contains(table.selectedRow) else { toolMessage("先选择一行", "点击文件行后可在 Finder 中查看。"); return }
        NSWorkspace.shared.activateFileViewerSelecting([rows[table.selectedRow].file.url])
    }
    @objc func clean() {
        guard !busy, !selected.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "将 \(selected.count) 个副本移入废纸篓？"
        alert.informativeText = "每组第一份文件会保留。相同内容不等于副本无用，清理前请确认这些路径不再需要。\n\n操作前将再次读取内容核对，变化或访问失败的文件会跳过。只移入废纸篓，不自动清空；最多处理 1,000 个副本。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; update(); table.reloadData(); status.stringValue = "正在重新核对内容并移动副本…"
        let groups = result.groups, paths = selected
        queue.async { [weak self] in
            let outcome = DuplicateCleaner.trash(groups, selected: paths)
            DispatchQueue.main.async { self?.applyTrashResult(outcome) }
        }
    }
    func applyTrashResult(_ outcome: DuplicateTrashResult) {
        busy = false; selected = []
        // Require a new scan after cleanup so no old group can serve as evidence for another operation.
        rows = []; result = DuplicateResult(); summary.stringValue = "已处理，请重新查找"
        status.stringValue = "已移入废纸篓 \(outcome.moved.count) 个副本 · 失败 / 跳过 \(outcome.errors.count) 项；尚未清空废纸篓。"
        report = status.stringValue + "\n\n" + outcome.moved.map(\.path).joined(separator: "\n") + "\n\n" + outcome.errors.joined(separator: "\n")
        table.reloadData(); update()
    }
    @objc func showReport() { toolReport("重复文件详情", report) }
}

final class NetworkTool: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(), table = NSTableView()
    let healthView = NSView(), contentHost = NSView()
    let modes = NSSegmentedControl(labels: ["连接检查", "网络抓包"], trackingMode: .selectOne, target: nil, action: nil)
    let capture = PacketCaptureTool()
    let target = NSTextField(string: "www.apple.com")
    let preset = NSPopUpButton()
    let startButton = NSButton(title: "开始检查", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消检查", target: nil, action: nil)
    let summary = label("尚未检查", size: 24, weight: .semibold)
    let status = label("点击检查后读取本地连接配置，并向目标发送 DNS 查询及 HTTPS HEAD 请求。", size: 12, color: .secondaryLabelColor)
    let detail = label("选择一项查看完整说明。", size: 12, color: .secondaryLabelColor)
    let queue = DispatchQueue(label: "com.hb.macpulse.network.health", qos: .utility)
    var busy = false
    var cancellation: DiskCancellation?
    var result: NetworkHealthResult?
    var runner: (String, DiskCancellation, @escaping (String) -> Void) throws -> NetworkHealthResult = {
        try NetworkHealth.run($0, cancellation: $1, progress: $2)
    }
    override init() {
        super.init()
        startButton.target = self; startButton.action = #selector(start)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        startButton.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        preset.addItems(withTitles: ["Apple", "百度"]); preset.target = self; preset.action = #selector(changePreset)
        target.placeholderString = "目标域名，如 www.apple.com"; target.setAccessibilityLabel("网络检查目标域名")
        target.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        for (id, title, width) in [("item", "检查项目", 150.0), ("state", "结果", 100.0), ("detail", "检查说明", 790.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width
            col.minWidth = id == "detail" ? 400 : width; table.addTableColumn(col)
        }
        table.delegate = self; table.dataSource = self; table.style = .plain
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 84; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        detail.isSelectable = true; detail.maximumNumberOfLines = 3
        fillTool(stack([
            stack([label("网络健康", size: 26, weight: .bold), label("分层检查连接，给出可核对的线索", size: 13, color: .secondaryLabelColor)], spacing: 5),
            inset(summary),
            stack([label("目标域名", size: 12), target, preset, NSView(), cancelButton, startButton], vertical: false),
            label("仅在点击时检查此目标，不上传文件或进程信息，不进行测速下载；不修改 DNS、代理、VPN 或 Wi-Fi。", size: 11, color: .secondaryLabelColor),
            scroll, detail,
            label("一个网站不可达不代表整个网络故障。可换目标复测；请求可能经过系统代理 / VPN。总耗时包含 DNS、代理和握手，不是网速。", size: 11, color: accent),
            stack([status, NSView(), NSButton(title: "复制检查报告", target: self, action: #selector(copyReport))], vertical: false)
        ], spacing: 15), in: healthView)
        modes.selectedSegment = 0; modes.target = self; modes.action = #selector(switchMode)
        for child in [healthView, capture.view] {
            contentHost.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor), child.topAnchor.constraint(equalTo: contentHost.topAnchor),
                child.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)])
        }
        fillTool(stack([modes, contentHost], spacing: 14), in: view)
        switchMode()
        update()
    }
    @objc func switchMode() { healthView.isHidden = modes.selectedSegment != 0; capture.view.isHidden = modes.selectedSegment != 1 }
    deinit { cancellation?.cancel() }
    func update() {
        startButton.isEnabled = !busy; target.isEnabled = !busy; preset.isEnabled = !busy; cancelButton.isEnabled = busy
    }
    @objc func changePreset() { if !busy { target.stringValue = preset.indexOfSelectedItem == 1 ? "www.baidu.com" : "www.apple.com" } }
    @objc func start() {
        guard !busy else { return }
        let host: String
        do { host = try NetworkHealth.host(target.stringValue) }
        catch { toolMessage("目标域名格式不正确", error.localizedDescription); return }
        target.stringValue = host; result = nil; table.reloadData()
        busy = true; let token = DiskCancellation(); cancellation = token; update()
        summary.stringValue = "检查中…"; status.stringValue = "读取本地状态…"
        detail.stringValue = "选择一项查看完整说明。"
        let run = runner
        queue.async { [weak self] in
            do {
                let outcome = try run(host, token, { message in DispatchQueue.main.async { [weak self] in self?.status.stringValue = message } })
                DispatchQueue.main.async { self?.receive(outcome) }
            } catch {
                DispatchQueue.main.async {
                    self?.receive(NetworkHealthResult(host: host, checks: [HealthCheck(title: "检查", level: .failed, detail: error.localizedDescription)]))
                }
            }
        }
    }
    func receive(_ outcome: NetworkHealthResult) {
        result = outcome; busy = false; cancellation = nil; summary.stringValue = outcome.summary
        status.stringValue = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) · 目标 \(outcome.host) · 本次快照"
        table.reloadData(); update()
    }
    @objc func cancel() { cancellation?.cancel(); cancelButton.isEnabled = false; status.stringValue = "正在停止；DNS 查询最长等待约 3 秒…" }
    func numberOfRows(in tableView: NSTableView) -> Int { result?.checks.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let checks = result?.checks, checks.indices.contains(row) else { return nil }; let item = checks[row]
        if column?.identifier.rawValue == "item" { return label(item.title, size: 13, weight: .medium) }
        if column?.identifier.rawValue == "state" {
            let text = item.level == .good ? "通过" : item.level == .warning ? "留意" : item.level == .failed ? "需排查" : "配置"
            return label(text, size: 12, weight: .medium, color: item.level == .good ? .systemGreen :
                item.level == .warning ? .systemOrange : item.level == .failed ? .systemRed : .secondaryLabelColor)
        }
        let field = label(item.detail, size: 12); field.maximumNumberOfLines = 3; field.toolTip = item.detail; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let checks = result?.checks, checks.indices.contains(table.selectedRow) { detail.stringValue = checks[table.selectedRow].detail }
    }
    @objc func copyReport() {
        guard let result = result else { toolMessage("尚无检查结果", "请先执行一次网络健康检查。"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.report, forType: .string)
        status.stringValue = "报告已复制，含目标域名和本机网络配置；分享前请自行核对。"
    }
}
