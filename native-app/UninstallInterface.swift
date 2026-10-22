import AppKit
import UniformTypeIdentifiers

final class UninstallTool: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let view = NSView(), table = NSTableView()
    let mode = NSSegmentedControl(labels: ["应用卸载", "疑似残留"], trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    let picker = NSPopUpButton()
    let refreshButton = NSButton(title: "刷新应用列表", target: nil, action: nil)
    let chooseButton = NSButton(title: "选择应用…", target: nil, action: nil)
    let inspectButton = NSButton(title: "检查关联文件", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消检查", target: nil, action: nil)
    let appOnlyButton = NSButton(title: "只选应用本体", target: nil, action: nil)
    let selectButton = NSButton(title: "选择可处理项", target: nil, action: nil)
    let clearButton = NSButton(title: "取消选择", target: nil, action: nil)
    let cleanButton = NSButton(title: "移入废纸篓…", target: nil, action: nil)
    let summary = label("选择应用，先检查再处理", size: 23, weight: .semibold)
    let identityLabel = label("支持 /Applications 与当前用户 Applications 中的普通应用。", size: 11, color: .secondaryLabelColor)
    let status = label("加载应用清单不会自动检查关联文件，也不会自动卸载。", size: 11, color: .secondaryLabelColor)
    let detail = label("点击一行查看完整路径和匹配依据。", size: 11, color: .secondaryLabelColor)
    let selectedLabel = label("未选择任何项目", size: 12)
    let queue = DispatchQueue(label: "com.hb.macpulse.uninstaller", qos: .utility)
    var environment: UninstallEnvironment
    var targets: [UninstallTarget] = []
    var filtered: [UninstallTarget] = []
    var currentReport: UninstallReport?
    var selected = Set<String>()
    var lastReport = "尚无检查或处理记录。"
    var busy = false, loaded = false
    private var displayedMode = 0
    var cancellation: DiskCancellation?
    var target: UninstallTarget? { filtered.indices.contains(picker.indexOfSelectedItem) ? filtered[picker.indexOfSelectedItem] : nil }
    init(environment: UninstallEnvironment = UninstallEnvironment()) {
        self.environment = environment; super.init()
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changeMode)
        search.placeholderString = "搜索应用名称或标识"; search.delegate = self
        picker.target = self; picker.action = #selector(changeTarget)
        picker.setAccessibilityLabel("待检查的应用或疑似残留")
        for (button, action) in [(refreshButton, #selector(refresh)), (chooseButton, #selector(chooseApplication)),
            (inspectButton, #selector(inspect)), (cancelButton, #selector(cancel)), (appOnlyButton, #selector(selectApp)),
            (selectButton, #selector(selectEligible)), (clearButton, #selector(clearSelection)), (cleanButton, #selector(clean))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        for (id, title, width) in [("check", "选择", 75.0), ("kind", "类型", 145.0), ("path", "文件 / 路径", 460.0),
                                   ("size", "估算占用", 100.0), ("state", "匹配 / 保护说明", 250.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width
            col.minWidth = id == "path" ? 220 : width; table.addTableColumn(col)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 66; table.style = .plain
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        search.widthAnchor.constraint(equalToConstant: 235).isActive = true
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        identityLabel.isSelectable = true; identityLabel.lineBreakMode = .byTruncatingMiddle
        detail.isSelectable = true; detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byTruncatingMiddle
        fillTool(stack([
            stack([label("应用卸载与残留检查", size: 26, weight: .bold),
                   label("看清归属与影响，再决定移入废纸篓", size: 13, color: .secondaryLabelColor)], spacing: 5),
            inset(summary),
            stack([mode, search, NSView(), refreshButton, chooseButton], vertical: false),
            stack([picker, NSView(), cancelButton, inspectButton], vertical: false),
            identityLabel,
            label("默认不勾选。应用标识匹配供核对；应用数据可能包含数据库、配置和登录状态，请先备份。疑似残留不等于无用文件。", size: 11, color: .secondaryLabelColor),
            scroll,
            stack([detail, NSView(), NSButton(title: "在 Finder 中显示", target: self, action: #selector(reveal))], vertical: false),
            stack([appOnlyButton, selectButton, clearButton, selectedLabel, NSView(), cleanButton], vertical: false),
            label("系统应用、轻诊自身、运行中的应用受到保护；名称匹配、沙盒文档与后台服务仅查看。共享容器、钥匙串和系统扩展不处理。", size: 11, color: accent),
            label("带官方卸载器的软件请优先使用官方程序。这里只移入废纸篓，不提权、不自动清空；应用移走后仍可能有未覆盖的组件。", size: 11, color: .secondaryLabelColor),
            stack([status, NSView(), NSButton(title: "查看详情", target: self, action: #selector(showReport)),
                   NSButton(title: "官方卸载说明", target: self, action: #selector(openHelp))], vertical: false)
        ], spacing: 12), in: view)
        update()
    }
    deinit { cancellation?.cancel() }
    func ensureLoaded() { if !loaded && !busy { refresh() } }
    func update() {
        let allowed = Set((currentReport?.items ?? []).filter(\.selectable).map { $0.url.path })
        selected.formIntersection(allowed)
        mode.isEnabled = !busy; search.isEnabled = !busy; picker.isEnabled = !busy && !filtered.isEmpty
        refreshButton.isEnabled = !busy; chooseButton.isEnabled = !busy && mode.selectedSegment == 0
        inspectButton.isEnabled = !busy && target != nil; cancelButton.isEnabled = busy && cancellation != nil
        appOnlyButton.isEnabled = !busy && currentReport?.items.contains(where: { $0.kind == .application && $0.selectable }) == true
        selectButton.isEnabled = !busy && !allowed.isEmpty; clearButton.isEnabled = !busy && !selected.isEmpty
        cleanButton.isEnabled = !busy && !selected.isEmpty && currentReport?.cancelled == false
        selectedLabel.stringValue = "已选 \(selected.count) 项 · \(byteText((currentReport?.items ?? []).filter { selected.contains($0.url.path) }.reduce(0) { $0 + ($1.tree?.allocated ?? 0) }))"
    }
    @objc func changeMode() {
        guard !busy else { mode.selectedSegment = displayedMode; return }
        displayedMode = mode.selectedSegment; search.stringValue = ""; refresh()
    }
    @objc func refresh() {
        guard !busy else { return }
        busy = true; loaded = true; currentReport = nil; selected = []; table.reloadData()
        let token = DiskCancellation(); cancellation = token; update()
        status.stringValue = mode.selectedSegment == 0 ? "读取常用应用目录…" : "检查常用目录中的疑似残留标识…"
        let orphan = mode.selectedSegment == 1, environment = self.environment
        queue.async { [weak self] in
            let targets: [UninstallTarget], errors: [String]
            if orphan {
                let result = UninstallScanner.residues(environment, cancellation: token); targets = result.targets; errors = result.errors
            } else {
                let result = UninstallCatalog.read(environment, cancellation: token)
                targets = result.applications.map { UninstallTarget(application: $0) }; errors = result.errors
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.targets = targets; self.busy = false; self.cancellation = nil
                self.lastReport = errors.joined(separator: "\n")
                self.filterTargets()
                self.status.stringValue = token.cancelled ? "已取消，当前清单可能不完整。" :
                    "找到 \(targets.count) 项\(errors.isEmpty ? "" : " · 部分位置未覆盖，见详情")；选择后点击“检查关联文件”。"
                self.update()
            }
        }
    }
    func filterTargets() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = targets.filter { query.isEmpty || ($0.name + " " + $0.identifier).localizedCaseInsensitiveContains(query) }
        picker.removeAllItems()
        for target in filtered { picker.addItem(withTitle: "\(target.name) · \(target.orphan ? "疑似残留" : target.identifier)") }
        if filtered.isEmpty { picker.addItem(withTitle: "未找到匹配项，请刷新或选择应用") }
        changeTarget()
    }
    func controlTextDidChange(_ obj: Notification) { if !busy { filterTargets() } }
    @objc func changeTarget() {
        guard !busy else { return }
        currentReport = nil; selected = []; table.reloadData()
        summary.stringValue = target?.name ?? "选择应用，先检查再处理"
        identityLabel.stringValue = target.map { $0.orphan ? "\($0.identifier) · 常用目录及系统登记中未找到应用，仍需确认是否真的已卸载。" :
            "\($0.identifier) · \($0.application!.url.path)" } ?? "支持 /Applications 与当前用户 Applications 中的普通应用。"
        detail.stringValue = "点击一行查看完整路径和匹配依据。"; update()
    }
    func useApplication(_ url: URL) throws {
        guard !busy else { throw DiskError.message("请等待当前操作结束。") }
        let app = try UninstallApplication.read(url, environment: environment)
        mode.selectedSegment = 0; displayedMode = 0; search.stringValue = ""
        targets.removeAll { $0.application?.url.path == app.url.path }; targets.insert(UninstallTarget(application: app), at: 0)
        filterTargets()
    }
    @objc func chooseApplication() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = environment.applicationRoots.first; panel.prompt = "选择并检查"
        panel.message = "选择常用应用目录内的 .app；随后仅检查关联文件，不会自动卸载。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try useApplication(url); inspect() } catch { toolMessage("无法选择此应用", error.localizedDescription) }
    }
    @objc func inspect() {
        guard !busy, let target = target else { return }
        busy = true; selected = []; currentReport = nil; table.reloadData()
        let token = DiskCancellation(); cancellation = token; update()
        summary.stringValue = "检查中…"; status.stringValue = "统计应用与精确标识匹配路径，只读取元数据…"
        let environment = self.environment
        queue.async { [weak self] in
            let report = UninstallScanner.scan(target, environment: environment, cancellation: token)
            DispatchQueue.main.async { self?.receive(report) }
        }
    }
    func receive(_ report: UninstallReport) {
        currentReport = report; selected = []; busy = false; cancellation = nil; lastReport = report.text
        summary.stringValue = report.protection ?? "\(report.items.count) 项 · \(byteText(report.items.reduce(0) { $0 + ($1.tree?.allocated ?? 0) })) 已统计占用"
        status.stringValue = report.cancelled ? "已取消检查，不能使用本次结果清理。" :
            "\(report.items.filter(\.selectable).count) 项可勾选 · \(report.items.filter { !$0.selectable }.count) 项仅查看\(report.errors.isEmpty ? "" : " · 部分位置无法读取，见详情")"
        table.reloadData(); update()
    }
    @objc func cancel() { cancellation?.cancel(); cancelButton.isEnabled = false; status.stringValue = "正在停止元数据检查…" }
    func numberOfRows(in tableView: NSTableView) -> Int { currentReport?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let items = currentReport?.items, items.indices.contains(row) else { return nil }; let item = items[row]
        switch column?.identifier.rawValue {
        case "check":
            let button = NSButton(checkboxWithTitle: item.selectable ? "" : "仅查看", target: self, action: #selector(toggle(_:)))
            button.tag = row; button.isEnabled = !busy && item.selectable; button.state = selected.contains(item.url.path) ? .on : .off
            button.setAccessibilityLabel("\(item.selectable ? "选择" : "仅查看") \(item.url.lastPathComponent)"); return button
        case "kind": return label(item.kind.title, size: 11, color: item.kind == .support ? .systemOrange : .labelColor)
        case "path":
            let name = label(item.url.lastPathComponent, size: 12, weight: .medium)
            let path = label(item.url.deletingLastPathComponent().path, size: 10, color: .secondaryLabelColor)
            for field in [name, path] { field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle }
            let cell = stack([name, path], spacing: 4); cell.toolTip = item.url.path; return cell
        case "size": return label(item.tree.map { ( $0.complete ? "" : "部分 " ) + byteText($0.allocated) } ?? "未统计", size: 11)
        default:
            let field = label(item.protectedReason ?? item.basis, size: 11, color: item.selectable ? .secondaryLabelColor : .systemOrange)
            field.maximumNumberOfLines = 3; field.toolTip = item.protectedReason ?? item.basis; return field
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let items = currentReport?.items, items.indices.contains(table.selectedRow) {
            let item = items[table.selectedRow]; detail.stringValue = "\(item.url.path)\n依据：\(item.basis)；\(item.protectedReason ?? "默认未选，操作前将重新校验文件树。")"
        }
    }
    @objc func toggle(_ sender: NSButton) {
        guard !busy, let items = currentReport?.items, items.indices.contains(sender.tag), items[sender.tag].selectable else { return }
        let path = items[sender.tag].url.path
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
        update()
    }
    @objc func selectApp() {
        guard !busy else { return }
        selected = Set((currentReport?.items ?? []).filter { $0.kind == .application && $0.selectable }.map { $0.url.path })
        update(); table.reloadData()
    }
    @objc func selectEligible() {
        guard !busy else { return }
        selected = Set((currentReport?.items ?? []).filter(\.selectable).prefix(20).map { $0.url.path })
        update(); table.reloadData()
    }
    @objc func clearSelection() { guard !busy else { return }; selected = []; update(); table.reloadData() }
    @objc func clean() {
        guard !busy, let report = currentReport, !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = report.target.orphan ? "确认这是不再需要的已卸载应用数据？" : "将所选应用和文件移入废纸篓？"
        alert.informativeText = "\(report.target.name)\n\(selected.count) 项。应用数据可能包含数据库、配置和登录状态，请先备份。\n\n" +
            (report.target.orphan ? "没有找到应用不能证明数据无用；确认对应应用已卸载且这些数据不再需要后再继续。\n\n" :
                "位于 /Applications 的应用移走后会影响其他使用者；软件如有官方卸载器，请优先使用。\n\n") +
            report.items.filter { selected.contains($0.url.path) }.map { $0.url.path }.joined(separator: "\n") +
            "\n\n会重新检查运行状态与文件树。只移入废纸篓，不自动清空；失败项保留原处。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: report.target.orphan ? "已确认，移入废纸篓" : "移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; cancellation = nil; update(); table.reloadData()
        status.stringValue = "正在重新核对并移动所选项目…"; let paths = selected, environment = self.environment
        queue.async { [weak self] in
            let outcome = UninstallCleaner.trash(report, selected: paths, environment: environment)
            DispatchQueue.main.async { self?.applyTrashResult(outcome) }
        }
    }
    func applyTrashResult(_ result: UninstallTrashResult) {
        busy = false; currentReport = nil; selected = []; table.reloadData()
        summary.stringValue = "已移入废纸篓 \(result.moved.count) 项"
        status.stringValue = "失败 / 跳过 \(result.errors.count) 项；请刷新列表或重新检查，尚未清空废纸篓。"
        lastReport = status.stringValue + "\n\n已移动：\n" + result.moved.map(\.path).joined(separator: "\n") +
            "\n\n失败 / 跳过：\n" + result.errors.joined(separator: "\n")
        detail.stringValue = "可在 Finder 废纸篓中放回；不要使用旧检查结果再次操作。"; update()
    }
    @objc func reveal() {
        let url: URL?
        if let items = currentReport?.items, items.indices.contains(table.selectedRow) { url = items[table.selectedRow].url }
        else { url = target?.application?.url }
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { toolMessage("先选择现有项目", "检查后点击文件行，再在 Finder 中确认。"); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc func showReport() { toolReport("卸载 / 残留检查详情", lastReport) }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://support.apple.com/102610")!) }
}
