import AppKit

final class DiskSelectionHeader: NSTableHeaderView {
    let selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectAll.allowsMixedState = true
        selectAll.font = .systemFont(ofSize: 11)
        selectAll.setAccessibilityLabel("全选扫描结果")
        selectAll.toolTip = "全选本次扫描结果；再次点击取消全选"
        addSubview(selectAll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        return [selectAll] + children.filter { ($0 as? NSView) !== selectAll }
    }
    override func layout() {
        super.layout()
        guard let table = tableView, !table.tableColumns.isEmpty else { return }
        selectAll.frame = headerRect(ofColumn: 0).insetBy(dx: 7, dy: 2)
    }
}

struct DiskTabState {
    let rootPath: String
    var files: [DiskCandidate]
    var selected: Set<String>
    var summary: String
    var summaryDetail: String
    let status: String
    let report: String
    let permissionVisible: Bool
    let permissionMessage: String
    let scanTitle: String
    var detail: String
    var focusedPath: String?
    let scrollOrigin: NSPoint
    mutating func removeMoved(_ paths: Set<String>) {
        let before = files.count
        files.removeAll { paths.contains($0.url.path) }
        guard before != files.count else { return }
        selected.subtract(paths)
        summary = "剩余 \(files.count) 个扫描结果"
        summaryDetail = "已同步其他扫描范围的清理结果；部分文件可能已变化"
        if let path = focusedPath, paths.contains(path) {
            focusedPath = nil; detail = "所选文件已移入废纸篓。"
        }
    }
}

final class DiskTool: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    let table = NSTableView()
    let selectionHeader = DiskSelectionHeader(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
    let category = NSSegmentedControl(labels: DiskKind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let scanButton = NSButton(title: "开始扫描", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消扫描", target: nil, action: nil)
    let wholeDiskButton = NSButton(title: "已选：全盘", target: nil, action: nil)
    let folderButton = NSButton(title: "指定文件夹…", target: nil, action: nil)
    let cleanButton = NSButton(title: "移入废纸篓…", target: nil, action: nil)
    let selectionButton = NSButton(title: "选择本页结果", target: nil, action: nil)
    let capacity = label("正在读取容量…", size: 24, weight: .semibold)
    let capacityDetail = label("", size: 11, color: .secondaryLabelColor)
    let found = label("尚未扫描", size: 24, weight: .semibold)
    let foundDetail = label("只读扫描 · 所有文件默认不勾选", size: 11, color: .secondaryLabelColor)
    let explanation = label("", size: 12, color: .secondaryLabelColor)
    let folderLabel = label("", size: 11, color: .secondaryLabelColor)
    let selectedLabel = label("未选择文件", size: 12, weight: .medium)
    let detail = label("选择一行查看完整路径；可先在 Finder 中确认文件用途。", size: 11, color: .secondaryLabelColor)
    let status = label("点击开始扫描，只读取文件元数据，不读取文件内容。", size: 11, color: .secondaryLabelColor)
    let reportButton = NSButton(title: "查看扫描 / 清理详情", target: nil, action: nil)
    let permissionMessage = label("", size: 12, color: .systemOrange)
    let permissionSettingsButton = NSButton(title: "打开权限设置…", target: nil, action: nil)
    let permissionFolderButton = NSButton(title: "重新选择文件夹…", target: nil, action: nil)
    let permissionHint = label("由你确认允许访问；工具不会自动更改系统权限。", size: 11, color: .secondaryLabelColor)
    let permissionPanel = NSStackView()
    let queue = DispatchQueue(label: "com.hb.macpulse.disk", qos: .utility)
    let home: URL
    let wholeDiskRoot: URL
    var largeUsesWholeDisk = true
    var largeFolder: URL
    var hasChosenLargeFolder = false
    private var panelFolder: URL?
    var files: [DiskCandidate] = []
    var selected = Set<String>()
    var cancellation: DiskCancellation?
    var busy = false
    var report = "尚无扫描或清理记录。"
    private var displayedKind: DiskKind?
    private var displayedRoot = ""
    private var displayedKey = ""
    private var tabStates: [String: DiskTabState] = [:]
    var currentKey: String { "\(kind.rawValue):\(kind == .large && largeUsesWholeDisk ? "disk" : "folder"):\(rootURL.standardizedFileURL.path)" }
    var kind: DiskKind { DiskKind(rawValue: category.selectedSegment) ?? .caches }
    var isFullScan: Bool { kind == .large && largeUsesWholeDisk }
    var startScanTitle: String {
        if isFullScan { return "开始全盘扫描" }
        return kind == .large && !hasChosenLargeFolder ? "选择并扫描…" : "开始扫描"
    }
    private func updateScopeControl() {
        wholeDiskButton.title = largeUsesWholeDisk ? "已选：全盘" : "切换到全盘"
        wholeDiskButton.state = largeUsesWholeDisk ? .on : .off
        wholeDiskButton.isEnabled = !busy && !largeUsesWholeDisk
        wholeDiskButton.toolTip = largeUsesWholeDisk ? "全盘范围已选中；点击右侧“开始全盘扫描”开始检查。" :
            "切换到启动磁盘范围；之后点击右侧“开始全盘扫描”。"
        scanButton.toolTip = isFullScan ? "开始只读扫描本机启动磁盘，扫描中可取消。" : "开始扫描当前所示范围。"
    }
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, wholeDiskRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        self.home = home; self.wholeDiskRoot = wholeDiskRoot
        largeFolder = home.appendingPathComponent("Downloads")
        super.init(); build(); changeCategory(); refreshCapacity()
    }
    deinit { panelFolder?.stopAccessingSecurityScopedResource() }
    func build() {
        category.selectedSegment = 0; category.target = self; category.action = #selector(changeCategory)
        for (button, action) in [(scanButton, #selector(scan)), (cancelButton, #selector(cancel)), (folderButton, #selector(chooseFolder)), (wholeDiskButton, #selector(useWholeDisk)),
                                  (cleanButton, #selector(clean)), (selectionButton, #selector(selectResults)), (reportButton, #selector(showReport)),
                                  (permissionSettingsButton, #selector(openPermissionSettings)), (permissionFolderButton, #selector(chooseFolder))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        wholeDiskButton.setButtonType(.toggle)
        cancelButton.isEnabled = false; cleanButton.isEnabled = false; selectionButton.isEnabled = false
        let intro = stack([label("磁盘空间", size: 26, weight: .bold), label("先看清文件，再决定清理", size: 13, color: .secondaryLabelColor)], spacing: 5)
        let refresh = NSButton(title: "刷新容量", target: self, action: #selector(refreshCapacity)); refresh.bezelStyle = .rounded
        let header = stack([intro, NSView(), refresh], vertical: false)
        let storageCard = inset(stack([label("当前用户所在磁盘 · 系统报告可用空间", size: 12, color: .secondaryLabelColor), capacity, capacityDetail], spacing: 9))
        let candidatesCard = inset(stack([label("扫描结果 · 估算磁盘占用", size: 12, color: .secondaryLabelColor), found, foundDetail], spacing: 9))
        let cards = stack([storageCard, candidatesCard], vertical: false, spacing: 14); cards.distribution = .fillEqually
        let controls = stack([category, wholeDiskButton, folderButton, NSView(), cancelButton, scanButton], vertical: false)
        folderLabel.isSelectable = true; folderLabel.lineBreakMode = .byTruncatingMiddle
        for (id, title, width) in [("check", "", 80.0), ("file", "文件 / 路径", 440.0), ("size", "文件大小", 100.0), ("disk", "磁盘占用¹", 100.0), ("date", "最后修改", 115.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width
            col.minWidth = id == "file" ? 240 : width
            col.resizingMask = id == "file" ? .autoresizingMask : []; table.addTableColumn(col)
        }
        table.headerView = selectionHeader
        selectionHeader.selectAll.target = self; selectionHeader.selectAll.action = #selector(selectResults)
        table.delegate = self; table.dataSource = self; table.rowHeight = 48; table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth; table.columnAutoresizingStyle = .noColumnAutoresizing
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        detail.isSelectable = true; detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingMiddle
        let reveal = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealFile)); reveal.bezelStyle = .rounded
        let details = stack([detail, NSView(), reveal], vertical: false)
        let trash = NSButton(title: "打开废纸篓", target: self, action: #selector(openTrash)); trash.bezelStyle = .rounded
        let bottom = stack([selectionButton, selectedLabel, NSView(), trash, cleanButton], vertical: false)
        let warning = label("移入废纸篓后可在 Finder 中放回原处；只有清空废纸篓后才会释放空间。本工具不会自动清空。", size: 12, color: accent)
        let foot = stack([status, NSView(), reportButton], vertical: false)
        permissionPanel.orientation = .vertical; permissionPanel.alignment = .leading; permissionPanel.spacing = 7
        permissionPanel.addArrangedSubview(permissionMessage)
        permissionPanel.addArrangedSubview(stack([permissionSettingsButton, permissionFolderButton,
                                                   permissionHint], vertical: false))
        permissionMessage.widthAnchor.constraint(equalTo: permissionPanel.widthAnchor).isActive = true
        permissionPanel.isHidden = true
        let root = stack([header, cards, controls, explanation, folderLabel, permissionPanel, scroll, details, bottom, warning,
                          label("¹ 按文件分配块数估算；APFS 克隆、稀疏文件和磁盘快照会影响实际释放量。全盘模式可查看受保护文件，但不可勾选；不下载云端占位文件，不跟随链接。", size: 10, color: .secondaryLabelColor), foot], spacing: 13)
        view.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     cards.heightAnchor.constraint(equalToConstant: 116)])
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    @objc func refreshCapacity() {
        if let value = DiskCapacity.read(at: home) {
            capacity.stringValue = "\(byteText(value.free)) 可用"
            capacityDetail.stringValue = "总容量 \(byteText(value.total)) · 与所选外置磁盘可能不同 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
        } else { capacity.stringValue = "容量读取失败"; capacityDetail.stringValue = "请稍后刷新；不会以 0 冒充读数。" }
    }
    @objc func changeCategory() {
        guard !busy else { category.selectedSegment = displayedKind?.rawValue ?? 0; return }
        saveCurrentTab()
        displayedKind = kind; displayedRoot = rootURL.standardizedFileURL.path; displayedKey = currentKey
        explanation.stringValue = kind == .large && largeUsesWholeDisk ? "检查启动磁盘中至少 100 MiB 的文件，含系统和应用内部文件；受保护项仅查看。文件较多时耗时较长，可随时取消。" : kind.explanation
        wholeDiskButton.isHidden = kind != .large; updateScopeControl()
        folderButton.isHidden = kind != .large
        permissionFolderButton.isHidden = kind != .large
        folderLabel.stringValue = kind == .large && largeUsesWholeDisk ? "扫描范围：启动磁盘 \(rootURL.path)（不含外置 / 网络 / 辅助卷及重复入口；受权限限制）" : "扫描范围：\(rootURL.path)"
        permissionHint.stringValue = kind == .large && largeUsesWholeDisk ? "需更完整覆盖时，可自行在系统设置授予轻诊“完全磁盘访问权限”。" : "由你确认允许访问；不需要完全磁盘访问权限。"
        if let state = tabStates[currentKey], state.rootPath == displayedRoot {
            files = state.files; selected = state.selected.intersection(Set(state.files.map { $0.url.path }))
            found.stringValue = state.summary; foundDetail.stringValue = state.summaryDetail
            status.stringValue = state.status; report = state.report
            permissionPanel.isHidden = !state.permissionVisible; permissionMessage.stringValue = state.permissionMessage
            scanButton.title = state.scanTitle; detail.stringValue = state.detail
            table.reloadData(); table.deselectAll(nil)
            if let path = state.focusedPath, let index = files.firstIndex(where: { $0.url.path == path }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            updateSelection(); table.layoutSubtreeIfNeeded()
            if let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: max(0, min(state.scrollOrigin.x, table.frame.width - clip.bounds.width)),
                                        y: max(0, min(state.scrollOrigin.y, table.frame.height - clip.bounds.height))))
                scroll.reflectScrolledClipView(clip)
            }
        } else { resetCurrentResults() }
    }
    private func saveCurrentTab() {
        guard displayedKind != nil else { return }
        let focused = files.indices.contains(table.selectedRow) ? files[table.selectedRow].url.path : nil
        tabStates[displayedKey] = DiskTabState(rootPath: displayedRoot, files: files, selected: selected,
            summary: found.stringValue, summaryDetail: foundDetail.stringValue, status: status.stringValue, report: report,
            permissionVisible: !permissionPanel.isHidden, permissionMessage: permissionMessage.stringValue,
            scanTitle: scanButton.title, detail: detail.stringValue, focusedPath: focused,
            scrollOrigin: table.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    private func resetCurrentResults() {
        files = []; selected = []; report = "此页签尚无扫描或清理记录。"
        table.reloadData(); table.deselectAll(nil); updateSelection()
        permissionPanel.isHidden = true; permissionMessage.stringValue = ""
        scanButton.title = startScanTitle
        found.stringValue = "尚未扫描"; foundDetail.stringValue = "只读扫描 · 所有文件默认不勾选"
        status.stringValue = isFullScan ? "已选择全盘范围；点击右侧“开始全盘扫描”。" : "点击开始扫描；遇到权限限制会跳过并在详情中说明。"
        detail.stringValue = "选择一行查看完整路径；可先在 Finder 中确认文件用途。"
        if let scroll = table.enclosingScrollView { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    var rootURL: URL {
        kind == .caches ? home.appendingPathComponent("Library/Caches") : kind == .logs ? home.appendingPathComponent("Library/Logs") : (largeUsesWholeDisk ? wholeDiskRoot : largeFolder)
    }
    @objc func useWholeDisk() {
        guard !busy else { return }
        saveCurrentTab(); displayedKind = nil
        largeUsesWholeDisk = true; changeCategory()
    }
    @objc func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择要扫描的个人文件夹并点击“选择并扫描”。若之前拒绝访问，可重新选择；仍受限时请打开系统权限设置。"
        panel.prompt = "选择并扫描"; panel.directoryURL = largeFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try useLargeFolder(url)
            // NSOpenPanel starts access implicitly. Retain its original URL for this session and balance it on replacement/exit.
            panelFolder?.stopAccessingSecurityScopedResource(); panelFolder = url
            scan()
        } catch { url.stopAccessingSecurityScopedResource(); present("无法扫描此目录", error.localizedDescription) }
    }
    func useLargeFolder(_ url: URL) throws {
        guard !busy else { throw DiskError.message("请等待当前操作结束。") }
        _ = try DiskScope(root: url, kind: .large, home: home)
        saveCurrentTab()
        tabStates = tabStates.filter { !$0.key.hasPrefix("\(DiskKind.large.rawValue):folder:") }
        if displayedKind == .large { displayedKind = nil }
        largeFolder = url; hasChosenLargeFolder = true; largeUsesWholeDisk = false; changeCategory()
    }
    @objc func openPermissionSettings() {
        // Navigation only. The user grants access in System Settings; never reset TCC or broaden permissions.
        let page = kind == .large && largeUsesWholeDisk ? "Privacy_AllFiles" : "Privacy_FilesAndFolders"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)")!
        if !NSWorkspace.shared.open(url) {
            present("请打开文件夹权限设置", permissionInstructions)
        }
    }
    var permissionInstructions: String {
        if kind == .large && largeUsesWholeDisk {
            return "全盘扫描只覆盖当前允许访问的位置。可到“系统设置 → 隐私与安全性 → 完全磁盘访问权限”自行添加 / 开启轻诊，按系统要求重启应用后重试。也可通过“指定文件夹”缩小范围。工具不自动授予或重置权限；部分系统位置仍可能无法读取。"
        }
        return "若此前点击了“不允许”，请到“系统设置 → 隐私与安全性 → 文件与文件夹 → 轻诊”，开启对应文件夹（如“下载文件夹”）的访问。返回后点击“重试扫描”；系统若要求重启应用，请退出并重新打开轻诊。也可重新选择有权限的个人文件夹。"
    }
    func setBusy(_ value: Bool, scanning: Bool = false) {
        busy = value; updateScopeControl(); category.isEnabled = !value; folderButton.isEnabled = !value; scanButton.isEnabled = !value
        cancelButton.isEnabled = value && scanning; selectionButton.isEnabled = !value && !files.isEmpty
        permissionFolderButton.isEnabled = !value; permissionSettingsButton.isEnabled = !value
        updateSelection(); table.reloadData()
    }
    @objc func scan() {
        guard !busy else { return }
        if kind == .large && !largeUsesWholeDisk && !hasChosenLargeFolder { chooseFolder(); return }
        let scope: DiskScope
        do { scope = try kind == .large && largeUsesWholeDisk ? DiskScope.wholeDisk(root: wholeDiskRoot, home: home) : DiskScope(root: rootURL, kind: kind, home: home) }
        catch { present("无法开始扫描", error.localizedDescription); return }
        tabStates.removeValue(forKey: currentKey); resetCurrentResults(); setBusy(true, scanning: true)
        permissionPanel.isHidden = true
        let token = DiskCancellation(); cancellation = token
        let active = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        status.stringValue = isFullScan ? "正在扫描启动磁盘…可点击“取消扫描”停止。" : "正在只读扫描…"
        found.stringValue = "扫描中…"
        queue.async { [weak self] in
            let result = DiskScanner.scan(scope, cancellation: token, activeBundleIDs: active, progress: { count in
                DispatchQueue.main.async { [weak self] in self?.status.stringValue = "已检查 \(count) 个项目…" }
            })
            DispatchQueue.main.async { self?.receive(result, scope: scope) }
        }
    }
    @objc func cancel() { cancellation?.cancel(); cancelButton.isEnabled = false; status.stringValue = "正在停止扫描…" }
    func receive(_ result: DiskScanResult, scope: DiskScope) {
        files = result.files; selected = []; cancellation = nil; setBusy(false)
        let completeness = result.statusTitle
        found.stringValue = result.rootFailure == nil ? "\(byteText(result.allocated)) · \(files.count) 个文件" : completeness
        foundDetail.stringValue = "\(completeness) · \(files.filter { !$0.cleanupAllowed }.count) 项仅查看 · 默认未选择"
        status.stringValue = "\(completeness) · 检查 \(result.inspected) 项 · 跳过 \(result.skipped) 项 · 错误详情最多保留 20 条"
        scanButton.title = result.errors.isEmpty ? startScanTitle : (isFullScan ? "重试全盘扫描" : "重试扫描")
        permissionPanel.isHidden = !result.hasPermissionError
        permissionFolderButton.isHidden = kind != .large
        if result.hasPermissionError {
            permissionMessage.stringValue = scope.isWholeDisk ? "部分位置无权访问，结果不完整；可打开权限设置后重试，或指定个人文件夹。" : "文件夹访问被拒绝。若之前点了“不允许”，请打开权限设置允许对应文件夹，然后重试。"
            foundDetail.stringValue = result.rootFailure != nil ? "未能扫描所选文件夹；下方可恢复访问或重新选择。" : "结果不完整，受限文件夹未参与扫描。"
        }
        report = "范围：\(scope.root.path)\n\(scope.kind.explanation)\n\(status.stringValue)\n符合条件：\(files.count) 个文件\n\n\(result.errors.isEmpty ? "无访问错误。" : result.errors.joined(separator: "\n"))"
        if scope.isWholeDisk {
            report += "\n\n全盘范围：本机启动磁盘；不含外置 / 网络 / 辅助卷及重复入口。持续遍历至结束或取消，不因 25 秒或 50,000 项限制而提前结束；访问受限或取消时结果不完整。\n共找到 \(result.matched) 个大文件，显示其中占用最大的 \(files.count) 个（最多 10,000 个）。\n仅查看：\(files.filter { !$0.cleanupAllowed }.count) 项。不会清理系统、应用包、Library 或其他用户文件。\n排除位置（最多 20 条）：\n" + result.excludedPaths.joined(separator: "\n")
        }
        if result.hasPermissionError { report += "\n\n\(permissionInstructions)" }
        refreshCapacity(); saveCurrentTab()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else { return nil }; let file = files[row]
        switch tableColumn?.identifier.rawValue {
        case "check":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFile(_:)))
            button.tag = row; button.state = selected.contains(file.url.path) ? .on : .off; button.isEnabled = !busy && file.cleanupAllowed
            button.title = file.cleanupAllowed ? "" : "仅查看"
            button.toolTip = file.cleanupAllowed ? "勾选后可移入废纸篓，操作前将再次校验。" : "受保护文件，仅可查看或在 Finder 中显示。"
            button.setAccessibilityLabel("\(file.cleanupAllowed ? "选择" : "仅查看") \(file.url.lastPathComponent)"); return button
        case "file":
            let name = label(file.url.lastPathComponent, size: 12, weight: .medium); name.maximumNumberOfLines = 1; name.lineBreakMode = .byTruncatingMiddle
            let path = label(file.url.deletingLastPathComponent().path, size: 10, color: .secondaryLabelColor); path.maximumNumberOfLines = 1; path.lineBreakMode = .byTruncatingMiddle
            let cell = stack([name, path], spacing: 3); cell.toolTip = file.url.path; return cell
        case "size": return label(byteText(file.logical), size: 12)
        case "disk": return label(byteText(file.allocated), size: 12)
        case "date": return label(DateFormatter.localizedString(from: file.modified, dateStyle: .short, timeStyle: .none), size: 11)
        default: return nil
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if files.indices.contains(table.selectedRow) { detail.stringValue = files[table.selectedRow].url.path }
    }
    @objc func toggleFile(_ sender: NSButton) {
        guard !busy, files.indices.contains(sender.tag), files[sender.tag].cleanupAllowed else { return }
        let path = files[sender.tag].url.path
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
        updateSelection()
    }
    @objc func selectResults() {
        guard !busy else { return }
        // Explicit action only; no scan ever preselects files.
        let paths = Set(files.filter { $0.cleanupAllowed }.map { $0.url.path })
        if !paths.isEmpty && paths.isSubset(of: selected) { selected = [] } else { selected = paths }
        table.reloadData(); updateSelection()
    }
    func updateSelection() {
        let eligible = Set(files.filter { $0.cleanupAllowed }.map { $0.url.path })
        selected.formIntersection(eligible)
        let items = files.filter { selected.contains($0.url.path) }
        selectedLabel.stringValue = "已选 \(items.count) 项 · 估算占用 \(byteText(items.reduce(0) { $0 + $1.allocated }))"
        let allSelected = !items.isEmpty && items.count == eligible.count
        selectionButton.title = allSelected ? "取消全选" : "全选结果"
        selectionButton.isEnabled = !busy && !eligible.isEmpty
        selectionHeader.selectAll.isEnabled = !busy && !eligible.isEmpty
        selectionHeader.selectAll.toolTip = "仅全选可清理的个人文件；受保护项不会选中。"
        selectionHeader.selectAll.state = allSelected ? .on : items.isEmpty ? .off : .mixed
        cleanButton.isEnabled = !busy && !items.isEmpty
    }
    @objc func revealFile() {
        guard files.indices.contains(table.selectedRow) else { present("先选择一行", "点击文件所在行后，可在 Finder 中查看。"); return }
        NSWorkspace.shared.activateFileViewerSelecting([files[table.selectedRow].url])
    }
    @objc func openTrash() {
        do {
            let url = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: home, create: false)
            if !NSWorkspace.shared.open(url) { present("无法打开废纸篓", "请从 Dock 中打开废纸篓。") }
        } catch { present("无法打开废纸篓", "请从 Dock 中打开废纸篓。\n\(error.localizedDescription)") }
    }
    @objc func clean() {
        guard !busy else { return }
        let items = files.filter { selected.contains($0.url.path) }; guard !items.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "将 \(items.count) 个文件移入废纸篓？"
        alert.informativeText = "估算磁盘占用 \(byteText(items.reduce(0) { $0 + $1.allocated }))。\n\n\(kind.explanation)\n\n移入后可在 Finder 废纸篓中放回。实际空间需清空废纸篓后释放，本工具不会自动清空。\n\n" + items.prefix(10).map { $0.url.lastPathComponent }.joined(separator: "\n") + (items.count > 10 ? "\n…其余 \(items.count - 10) 项请在列表中核对" : "")
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        setBusy(true); status.stringValue = "正在复核文件并移入废纸篓…"
        let active = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        queue.async { [weak self] in
            let result = DiskCleaner.trashSelection(items, activeBundleIDs: active)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.applyTrashResult(result)
                self.present("文件处理完成", self.status.stringValue + "\n详细路径与错误请点击“查看扫描 / 清理详情”。")
            }
        }
    }
    func applyTrashResult(_ result: DiskTrashResult) {
        let moved = Set(result.moved.map { $0.url.path }); files.removeAll { moved.contains($0.url.path) }
        // Full-disk and folder scans can overlap. Never restore an already-trashed file from another snapshot.
        for key in Array(tabStates.keys) { tabStates[key]?.removeMoved(moved) }
        selected = []; setBusy(false)
        found.stringValue = "剩余 \(files.count) 个扫描结果"
        foundDetail.stringValue = "部分结果可能已变化，建议重新扫描"
        detail.stringValue = "选择一行查看完整路径；可先在 Finder 中确认文件用途。"
        table.deselectAll(nil)
        status.stringValue = "已移入废纸篓 \(result.moved.count) 项（估算占用 \(byteText(result.allocated))）· 失败 / 跳过 \(result.errors.count) 项；尚未清空废纸篓。"
        report = status.stringValue + "\n\n已移动：\n" + result.moved.map { $0.url.path }.joined(separator: "\n") + "\n\n失败 / 跳过：\n" + result.errors.joined(separator: "\n")
        refreshCapacity(); saveCurrentTab()
    }
    @objc func showReport() {
        let alert = NSAlert(); alert.messageText = "扫描 / 清理详情"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 660, height: 340)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.string = report; text.isEditable = false
        text.font = .systemFont(ofSize: 12); text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "关闭"); alert.runModal()
    }
    func present(_ title: String, _ message: String) { let a = NSAlert(); a.messageText = title; a.informativeText = message; a.runModal() }
}
