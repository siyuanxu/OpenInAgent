import AppKit
import FinderSync
import OSLog

@objc(FinderSync)
final class FinderSync: FIFinderSync {
    private let logger = Logger(
        subsystem: "org.openinagent.OpenInAgent.FinderExtension",
        category: "FinderSync"
    )
    private var volumeObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        refreshMonitoredDirectories()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshMonitoredDirectories()
                }
            )
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            center.removeObserver(observer)
        }
    }

    override var toolbarItemName: String {
        "OpenInAgent"
    }

    override var toolbarItemToolTip: String {
        "用 Agent 或系统终端打开当前 Finder 目录"
    }

    override var toolbarItemImage: NSImage {
        let image = NSImage(
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "OpenInAgent"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        logger.notice("Finder requested menu kind: \(menuKind.rawValue, privacy: .public)")
        if menuKind == .toolbarItemMenu {
            return makeToolbarMenu()
        }
        guard menuKind == .contextualMenuForItems ||
                menuKind == .contextualMenuForContainer else {
            return nil
        }
        return makeContextMenu()
    }

    private func makeToolbarMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        addVisibleAgents(to: menu, contextual: false)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let initialize = menu.addItem(
            withTitle: "初始化 Agent 项目…",
            action: #selector(initializeProject(_:)),
            keyEquivalent: ""
        )
        initialize.target = self
        initialize.isEnabled = true
        let copy = menu.addItem(
            withTitle: "拷贝路径",
            action: #selector(copyPath(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.isEnabled = true
        menu.addItem(.separator())
        addSettingsItem(to: menu)
        return menu
    }

    private func makeContextMenu() -> NSMenu? {
        guard targetDirectory() != nil else {
            logger.notice("Finder context menu target was not a directory")
            return nil
        }
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        addVisibleAgents(to: menu, contextual: true)
        let initialize = menu.addItem(
            withTitle: "初始化 Agent 项目…",
            action: #selector(initializeProject(_:)),
            keyEquivalent: ""
        )
        initialize.target = self
        initialize.isEnabled = true
        addSettingsItem(to: menu)
        return menu
    }

    private func addVisibleAgents(to menu: NSMenu, contextual: Bool) {
        for agent in AgentPreferences.shared.visibleAgents {
            let item = menu.addItem(
                withTitle: contextual ? agent.contextMenuTitle : agent.toolbarTitle,
                action: action(for: agent),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
        }
    }

    private func addSettingsItem(to menu: NSMenu) {
        let item = menu.addItem(
            withTitle: "显示设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = true
    }

    // Finder transports its menus across processes. Keep the agent identity in
    // each action selector instead of relying on an item's representedObject.
    private func action(for agent: AgentKind) -> Selector {
        switch agent {
        case .codex: return #selector(openCodex(_:))
        case .dsh: return #selector(openDSH(_:))
        case .hermes: return #selector(openHermes(_:))
        case .zcode: return #selector(openZCode(_:))
        case .kimi: return #selector(openKimi(_:))
        case .terminal: return #selector(openTerminal(_:))
        }
    }

    @IBAction func openCodex(_ sender: Any?) { openAgent("codex") }
    @IBAction func openDSH(_ sender: Any?) { openAgent("dsh") }
    @IBAction func openHermes(_ sender: Any?) { openAgent("hermes") }
    @IBAction func openZCode(_ sender: Any?) { openAgent("zcode") }
    @IBAction func openKimi(_ sender: Any?) { openAgent("kimi") }
    @IBAction func openTerminal(_ sender: Any?) { openAgent("terminal") }

    @IBAction func openSettings(_ sender: Any?) {
        guard let url = URL(string: "openinagent://settings") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAgent(_ agent: String) {
        logger.notice("Finder selected agent: \(agent, privacy: .public)")
        openHost(action: "launch", agent: agent)
    }

    @IBAction func initializeProject(_ sender: Any?) {
        openHost(action: "initialize")
    }

    @IBAction func copyPath(_ sender: Any?) {
        if let directory = targetDirectory() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(directory.standardizedFileURL.path, forType: .string)
            logger.notice("Copied Finder directory path")
            return
        }
        openHost(action: "copy")
    }

    private func openHost(action: String, agent: String? = nil) {
        var components = URLComponents()
        components.scheme = "openinagent"
        components.host = action
        var queryItems: [URLQueryItem] = []
        if let agent {
            queryItems.append(URLQueryItem(name: "agent", value: agent))
        }
        if let directory = targetDirectory() {
            queryItems.append(URLQueryItem(name: "path", value: directory.standardizedFileURL.path))
        } else {
            queryItems.append(URLQueryItem(name: "source", value: "finder"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Could not construct the OpenInAgent URL")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            logger.error("The system could not open the OpenInAgent URL")
            return
        }
        logger.notice("Handed the Finder action to OpenInAgent")
    }

    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs()?.first {
            let values = try? selected.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
                ? selected.standardizedFileURL
                : selected.deletingLastPathComponent().standardizedFileURL
        }
        guard let target = controller.targetedURL() else { return nil }
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true ? target.standardizedFileURL : nil
    }

    private func refreshMonitoredDirectories() {
        var monitoredDirectories: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        monitoredDirectories.formUnion(mountedVolumes.map(\.standardizedFileURL))

        let additionalPaths = Bundle.main.object(
            forInfoDictionaryKey: "OpenInAgentAdditionalDirectoryPaths"
        ) as? [String] ?? []
        monitoredDirectories.formUnion(
            additionalPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        )
        FIFinderSyncController.default().directoryURLs = monitoredDirectories
        logger.notice("OpenInAgent Finder extension monitors \(monitoredDirectories.count) roots")
    }
}
