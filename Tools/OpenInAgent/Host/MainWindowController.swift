import AppKit
import FinderSync

final class MainWindowController: NSWindowController {
    init() {
        let viewController = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenInAgent"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 680, height: 620)
        window.contentViewController = viewController
        window.center()
        window.setFrameAutosaveName("OpenInAgentMainWindow")
        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class MainViewController: NSViewController, NSTextFieldDelegate {
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusTitle = NSTextField(labelWithString: "正在检查 Finder 扩展…")
    private let statusDetail = NSTextField(labelWithString: "")
    private let agentStatusLabel = NSTextField(wrappingLabelWithString: "正在检查 Agent…")
    private let pathField = NSTextField()
    private let descriptionField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let filePopup = NSPopUpButton()
    private let agentPopup = NSPopUpButton()
    private let startSessionCheckbox = NSButton(
        checkboxWithTitle: "把项目简述带入 Codex 启动会话",
        target: nil,
        action: nil
    )
    private let initializeButton = NSButton()
    private let openOnlyButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let resultTextView = NSTextView()
    private let resultScrollView = NSScrollView()
    private var selectedDirectory: URL?
    private var refreshTimer: Timer?
    private var isWorking = false

    private let typeItems: [(title: String, value: String)] = [
        ("通用项目", "generic"),
        ("工程资料", "engineering"),
        ("科研资料", "research"),
        ("文稿与申报", "writing"),
        ("软件开发", "software")
    ]

    private let fileItems: [(title: String, value: String)] = [
        ("AGENTS.md（推荐）", "agents"),
        ("AGENTS.md + SOUL.md", "both"),
        ("SOUL.md", "soul")
    ]

    override func loadView() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        view = visualEffect
        buildInterface()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshStatus()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refreshStatus() {
        refreshOpeningOptions()
        let status = OpenInAgentStatus.read()
        if status.extensionEnabled {
            statusDot.textColor = .systemGreen
            statusTitle.stringValue = "Finder 扩展已启用"
            statusDetail.stringValue = status.extensionRunning
                ? "扩展正在运行；Finder 工具栏和本地右键入口已就绪。"
                : "扩展已就绪，Finder 会在需要时自动启动它。"
        } else {
            statusDot.textColor = .systemOrange
            statusTitle.stringValue = "Finder 扩展尚未启用"
            statusDetail.stringValue = "请点击“管理 Finder 扩展”并打开 OpenInAgent。"
        }

        agentStatusLabel.stringValue = status.agents
            .map { "\($0.kind.displayName)：\($0.detail)" }
            .joined(separator: "　 · 　")
        if status.agents.isEmpty {
            agentStatusLabel.stringValue = "打开入口已全部隐藏，可在“显示设置…”中重新启用。"
        }
        agentStatusLabel.textColor = status.agents.allSatisfy(\.isAvailable)
            ? .secondaryLabelColor
            : .systemOrange
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择要初始化为 Agent 项目的文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let selectedDirectory {
            panel.directoryURL = selectedDirectory
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        selectedDirectory = url
        pathField.stringValue = url.path
        resultTextView.string = "已选择目录。填写简述后即可初始化。"
        updateButtons()
    }

    func chooseAndOpenFolder() {
        let panel = NSOpenPanel()
        guard let agent = selectedAgent else {
            showResult("请先在“显示设置…”中启用一个打开方式。", isError: true)
            return
        }
        panel.title = "选择要用 \(agent.displayName) 打开的文件夹"
        panel.prompt = "用 \(agent.displayName) 打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        openWithSelectedAgent(directory)
    }

    func receiveFinderDirectory(_ directory: URL, shouldOpen: Bool) {
        let normalized = directory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let values = try? normalized.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            showResult("Finder 传来的项目不是可访问的文件夹。", isError: true)
            return
        }

        selectedDirectory = normalized
        pathField.stringValue = normalized.path
        updateButtons()
        if shouldOpen {
            showResult("已从 Finder 接收“\(normalized.lastPathComponent)”。", isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openWithSelectedAgent(normalized)
            }
        } else {
            showResult("已从 Finder 接收“\(normalized.lastPathComponent)”，请填写项目简述。", isError: false)
        }
    }

    func showExternalResult(_ message: String, isError: Bool) {
        showResult(message, isError: isError)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateButtons()
    }

    @objc private func chooseFolderAction(_ sender: Any?) {
        chooseFolder()
    }

    @objc private func initializeProject(_ sender: Any?) {
        guard let selectedDirectory else {
            showResult("请先选择项目文件夹。", isError: true)
            return
        }

        let description = descriptionField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            showResult("请填写一句项目简述。", isError: true)
            view.window?.makeFirstResponder(descriptionField)
            return
        }

        guard let scriptURL = Bundle.main.url(
            forResource: "openinagent",
            withExtension: nil
        ) else {
            showResult("安装包中缺少项目初始化组件。", isError: true)
            return
        }

        let selectedType = typeItems[typePopup.indexOfSelectedItem].value
        let selectedFile = fileItems[filePopup.indexOfSelectedItem].value
        var arguments = [
            scriptURL.path,
            "init",
            selectedDirectory.path,
            "--description",
            description,
            "--type",
            selectedType,
            "--file",
            selectedFile
        ]
        let agent = selectedAgent
        if startSessionCheckbox.state != .on || agent != .codex {
            arguments.append("--no-start-session")
        }

        setWorking(true)
        resultTextView.textColor = .secondaryLabelColor
        resultTextView.string = "正在初始化项目…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self?.setWorking(false)
                    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { return }
                    let failed = process.terminationStatus != 0
                    self.showResult(text.isEmpty ? "项目初始化完成。" : text, isError: failed)
                    if !failed, let agent, agent != .codex {
                        self.launch(agent, directory: selectedDirectory, appendingTo: text)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setWorking(false)
                    self?.showResult(
                        "无法启动项目初始化组件：\(error.localizedDescription)",
                        isError: true
                    )
                }
            }
        }
    }

    @objc private func openSelectedFolder(_ sender: Any?) {
        guard let selectedDirectory else {
            showResult("请先选择一个文件夹。", isError: true)
            return
        }
        openWithSelectedAgent(selectedDirectory)
    }

    @objc private func manageExtension(_ sender: Any?) {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func revealApplication(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func descriptionChanged(_ sender: Any?) {
        updateButtons()
    }

    @objc private func startSessionChanged(_ sender: Any?) {
        updatePrimaryActionTitle()
    }

    @objc private func agentChanged(_ sender: Any?) {
        let isCodex = selectedAgent == .codex
        startSessionCheckbox.isEnabled = isCodex
        updatePrimaryActionTitle()
        refreshStatus()
    }

    private var selectedAgent: AgentKind? {
        guard let rawValue = agentPopup.selectedItem?.representedObject as? String else {
            return nil
        }
        return AgentKind(rawValue: rawValue)
    }

    private func refreshOpeningOptions() {
        let visible = AgentPreferences.shared.visibleAgents
        let identifiers = visible.map(\.rawValue)
        let current = agentPopup.itemArray.compactMap { $0.representedObject as? String }
        if current != identifiers || agentPopup.numberOfItems == 0 {
            let previous = selectedAgent
            agentPopup.removeAllItems()
            for agent in visible {
                agentPopup.addItem(withTitle: agent.displayName)
                agentPopup.lastItem?.representedObject = agent.rawValue
            }
            if let previous, let index = visible.firstIndex(of: previous) {
                agentPopup.selectItem(at: index)
            }
            if visible.isEmpty {
                agentPopup.addItem(withTitle: "未启用打开方式")
            }
        }
        agentPopup.isEnabled = !visible.isEmpty && !isWorking
        startSessionCheckbox.isEnabled = selectedAgent == .codex && !isWorking
        updateButtons()
    }

    private func openWithSelectedAgent(_ directory: URL) {
        guard let agent = selectedAgent else {
            showResult("请先在“显示设置…”中启用一个打开方式。", isError: true)
            return
        }
        launch(agent, directory: directory, appendingTo: nil)
    }

    private func launch(_ agent: AgentKind, directory: URL, appendingTo existing: String?) {
        if agent.launchesInBackground {
            setWorking(true)
            showResult(
                agent == .dsh ? "正在连接 DSH 桌面端并添加工作区…" : "正在系统终端中打开目录…",
                isError: false
            )
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Result<String, Error>
                do {
                    result = .success(try AgentLauncher.launch(agent, directory: directory))
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async {
                    self?.setWorking(false)
                    self?.finishLaunch(result, appendingTo: existing)
                }
            }
            return
        }

        let result: Result<String, Error>
        do {
            result = .success(try AgentLauncher.launch(agent, directory: directory))
        } catch {
            result = .failure(error)
        }
        finishLaunch(result, appendingTo: existing)
    }

    private func finishLaunch(_ result: Result<String, Error>, appendingTo existing: String?) {
        switch result {
        case .success(let message):
            let combined = [existing, message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            showResult(combined, isError: false)
        case .failure(let error):
            let combined = [existing, error.localizedDescription]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            showResult(combined, isError: true)
        }
    }

    private func setWorking(_ working: Bool) {
        isWorking = working
        if working {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        refreshOpeningOptions()
    }

    private func updateButtons() {
        updatePrimaryActionTitle()
        let hasDescription = !descriptionField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        initializeButton.isEnabled = !isWorking && selectedDirectory != nil && hasDescription
        openOnlyButton.isEnabled = !isWorking && selectedDirectory != nil && selectedAgent != nil
    }

    private func updatePrimaryActionTitle() {
        guard let selectedAgent else {
            initializeButton.title = "仅初始化项目"
            return
        }
        if selectedAgent == .codex && startSessionCheckbox.state == .on {
            initializeButton.title = "初始化并打开 Codex 启动会话"
        } else if selectedAgent == .codex {
            initializeButton.title = "仅初始化项目"
        } else {
            initializeButton.title = "初始化并打开 \(selectedAgent.displayName)"
        }
    }

    private func showResult(_ message: String, isError: Bool) {
        resultTextView.textColor = isError ? .systemRed : .secondaryLabelColor
        resultTextView.string = message
        resultTextView.scrollToEndOfDocument(nil)
    }

    private func buildInterface() {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -32),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 32)
        ])

        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(makeStatusCard())
        contentStack.addArrangedSubview(makeProjectCard())
        contentStack.addArrangedSubview(makeFinderCard())

        for arrangedView in contentStack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "OpenInAgent")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(labelWithString: "从 Finder 当前目录打开 Agent 或系统终端")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: icon.bottomAnchor)
        ])
        return container
    }

    private func makeStatusCard() -> NSView {
        statusDot.font = .systemFont(ofSize: 17, weight: .bold)
        statusDot.textColor = .secondaryLabelColor
        statusTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        agentStatusLabel.font = .systemFont(ofSize: 12)

        let textStack = NSStackView(views: [statusTitle, statusDetail, agentStatusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let statusRow = NSStackView(views: [statusDot, textStack])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 10

        let refreshButton = NSButton(
            title: "刷新状态",
            target: self,
            action: #selector(refreshStatusAction(_:))
        )
        refreshButton.bezelStyle = .rounded
        let manageButton = NSButton(
            title: "管理 Finder 扩展…",
            target: self,
            action: #selector(manageExtension(_:))
        )
        manageButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [refreshButton, manageButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)")
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.font = .systemFont(ofSize: 11)

        let footer = NSStackView(views: [buttons, NSView(), versionLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        return makeCard(views: [statusRow, footer])
    }

    @objc private func refreshStatusAction(_ sender: Any?) {
        refreshStatus()
    }

    private func makeProjectCard() -> NSView {
        let heading = makeSectionHeading(
            "初始化 Agent 项目",
            detail: "选择目录并生成项目说明；默认不会覆盖已有的 AGENTS.md 或 SOUL.md。"
        )

        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.placeholderString = "尚未选择文件夹"
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(
            title: "选择文件夹…",
            target: self,
            action: #selector(chooseFolderAction(_:))
        )
        chooseButton.bezelStyle = .rounded
        let pathRow = labeledRow("项目目录", control: pathField, trailing: chooseButton)

        descriptionField.placeholderString = "例如：整理项目资料并形成可核对报告"
        descriptionField.delegate = self
        let descriptionRow = labeledRow("项目简述", control: descriptionField)

        typePopup.addItems(withTitles: typeItems.map(\.title))
        filePopup.addItems(withTitles: fileItems.map(\.title))
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged(_:))
        startSessionCheckbox.state = .on
        startSessionCheckbox.toolTip = "Codex 可创建或复用该目录的 Local Project，并预填一条明确标记为项目启动会话的消息；DSH 会把目录加入桌面端工作区列表并唤醒应用，其他 Agent 打开目录。"
        startSessionCheckbox.target = self
        startSessionCheckbox.action = #selector(startSessionChanged(_:))

        let optionsRow = NSStackView()
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.spacing = 10
        let typeLabel = makeFormLabel("项目类型")
        let fileLabel = makeFormLabel("说明文件")
        optionsRow.addArrangedSubview(typeLabel)
        optionsRow.addArrangedSubview(typePopup)
        optionsRow.addArrangedSubview(fileLabel)
        optionsRow.addArrangedSubview(filePopup)
        optionsRow.addArrangedSubview(NSView())
        typeLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let settingsButton = NSButton(
            title: "显示设置…",
            target: NSApplication.shared.delegate,
            action: #selector(AppDelegate.showSettingsWindow)
        )
        settingsButton.bezelStyle = .rounded
        let agentRow = labeledRow("打开方式", control: agentPopup, trailing: settingsButton)

        initializeButton.title = "初始化并打开 Codex 启动会话"
        initializeButton.target = self
        initializeButton.action = #selector(initializeProject(_:))
        initializeButton.bezelStyle = .rounded
        initializeButton.keyEquivalent = "\r"
        initializeButton.contentTintColor = .controlAccentColor
        initializeButton.isEnabled = false

        openOnlyButton.title = "仅用所选方式打开"
        openOnlyButton.target = self
        openOnlyButton.action = #selector(openSelectedFolder(_:))
        openOnlyButton.bezelStyle = .rounded
        openOnlyButton.isEnabled = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let actionRow = NSStackView(views: [initializeButton, openOnlyButton, progressIndicator])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10

        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultTextView.textColor = .secondaryLabelColor
        resultTextView.string = "初始化结果会显示在这里。"
        resultTextView.textContainerInset = NSSize(width: 6, height: 6)
        resultScrollView.documentView = resultTextView
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.drawsBackground = true
        resultScrollView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55)
        resultScrollView.borderType = .bezelBorder
        resultScrollView.heightAnchor.constraint(equalToConstant: 78).isActive = true

        return makeCard(
            views: [
                heading,
                pathRow,
                descriptionRow,
                optionsRow,
                agentRow,
                startSessionCheckbox,
                actionRow,
                resultScrollView
            ]
        )
    }

    private func makeFinderCard() -> NSView {
        let heading = makeSectionHeading(
            "Finder 快捷入口",
            detail: "把 OpenInAgent 加入 Finder 工具栏后，可在普通目录和 OneDrive 当前目录打开 Agent 或系统终端。"
        )

        let note = NSTextField(
            wrappingLabelWithString: "在 Finder 中选“显示 → 自定工具栏…”，把 OpenInAgent 图标拖到工具栏。在“显示设置…”中勾选需要的入口；普通本地目录的右键菜单也会同步更新。OneDrive 目录请使用工具栏入口。"
        )
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let manageButton = NSButton(
            title: "管理 Finder 扩展…",
            target: self,
            action: #selector(manageExtension(_:))
        )
        manageButton.bezelStyle = .rounded
        let revealButton = NSButton(
            title: "在 Finder 中显示 App",
            target: self,
            action: #selector(revealApplication(_:))
        )
        revealButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [manageButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return makeCard(views: [heading, note, buttons])
    }

    private func makeCard(views: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 14
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.45)
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        guard let contentView = box.contentView else {
            return box
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private func makeSectionHeading(_ title: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func labeledRow(
        _ title: String,
        control: NSView,
        trailing: NSView? = nil
    ) -> NSView {
        let label = makeFormLabel(title)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        if let trailing {
            row.addArrangedSubview(trailing)
        }
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return row
    }

    private func makeFormLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
}
