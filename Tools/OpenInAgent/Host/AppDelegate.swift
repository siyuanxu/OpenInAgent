import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var keepInterfaceOpen = false
    private var handledExternalAction = false
    private let externalLaunchQueue = DispatchQueue(label: "org.openinagent.OpenInAgent.external-launch")
    private var pendingExternalLaunches = 0
    private var externalLaunchFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundledIcon = Bundle.main.url(
            forResource: "AppIcon",
            withExtension: "icns"
        ).flatMap { NSImage(contentsOf: $0) }
        if let icon = bundledIcon ?? NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
        configureMainMenu()
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !handledExternalAction else { return false }
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainViewController?.refreshStatus()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledExternalAction = true
        for url in urls {
            handleOpenURL(url)
        }
    }

    @objc private func showMainWindow() {
        keepInterfaceOpen = true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func showSettingsWindow() {
        keepInterfaceOpen = true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
            settingsWindowController?.onChange = { [weak self] in
                self?.mainViewController?.refreshStatus()
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func chooseProjectFolder() {
        showMainWindow()
        mainViewController?.chooseFolder()
    }

    @objc private func openFolderWithAgent() {
        showMainWindow()
        mainViewController?.chooseAndOpenFolder()
    }

    @objc private func refreshStatus() {
        showMainWindow()
        mainViewController?.refreshStatus()
    }

    @objc private func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private var mainViewController: MainViewController? {
        mainWindowController?.contentViewController as? MainViewController
    }

    private func handleOpenURL(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func query(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        guard scheme == "openinagent" else { return }
        guard let action = host else { return }
        if action == "settings" {
            showSettingsWindow()
            return
        }
        guard let directory = directory(path: query("path"), source: query("source")) else {
            showError("无法取得 Finder 当前目录。请在 OpenInAgent 中手动选择文件夹。")
            return
        }

        switch action {
        case "launch":
            guard let rawAgent = query("agent"), let agent = AgentKind(rawValue: rawAgent) else {
                showError("OpenInAgent 收到了未知的 Agent 类型。")
                return
            }
            prepareForBackgroundAction()
            launch(agent, directory: directory)
        case "initialize":
            showMainWindow()
            mainViewController?.receiveFinderDirectory(directory, shouldOpen: false)
        case "copy":
            prepareForBackgroundAction()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(directory.path, forType: .string)
            finishBackgroundAction()
        default:
            showError("OpenInAgent 收到了未知操作：\(action)")
        }
    }

    private func directory(path: String?, source: String?) -> URL? {
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? url : nil
        }
        if source == "finder" {
            return FinderDirectoryResolver.frontWindowDirectory()
        }
        return nil
    }

    private func launch(_ agent: AgentKind, directory: URL) {
        if agent.launchesInBackground {
            if pendingExternalLaunches == 0 {
                externalLaunchFailed = false
            }
            pendingExternalLaunches += 1
            externalLaunchQueue.async { [weak self] in
                let result: Result<String, Error>
                do {
                    result = .success(try AgentLauncher.launch(agent, directory: directory))
                } catch {
                    result = .failure(error)
                }
                DispatchQueue.main.async {
                    self?.finishExternalLaunch(result, directory: directory)
                }
            }
            return
        }

        do {
            _ = try AgentLauncher.launch(agent, directory: directory)
            finishBackgroundAction()
        } catch {
            mainViewController?.receiveFinderDirectory(directory, shouldOpen: false)
            showError(error.localizedDescription)
        }
    }

    private func finishExternalLaunch(
        _ result: Result<String, Error>,
        directory: URL
    ) {
        pendingExternalLaunches = max(0, pendingExternalLaunches - 1)
        if case .failure(let error) = result {
            externalLaunchFailed = true
            mainViewController?.receiveFinderDirectory(directory, shouldOpen: false)
            showError(error.localizedDescription)
        }
        if pendingExternalLaunches == 0, !externalLaunchFailed {
            finishBackgroundAction()
        }
    }

    private func prepareForBackgroundAction() {
        keepInterfaceOpen = false
        mainWindowController?.window?.orderOut(nil)
        settingsWindowController?.window?.orderOut(nil)
        NSApplication.shared.hide(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func finishBackgroundAction() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingExternalLaunches == 0,
                  !self.keepInterfaceOpen else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    private func showError(_ message: String) {
        showMainWindow()
        mainViewController?.showExternalResult(message, isError: true)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 OpenInAgent",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(
            withTitle: "显示设置…",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 OpenInAgent",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let initializeItem = fileMenu.addItem(
            withTitle: "选择要初始化的文件夹…",
            action: #selector(chooseProjectFolder),
            keyEquivalent: "n"
        )
        initializeItem.target = self
        let openItem = fileMenu.addItem(
            withTitle: "用 Agent 打开文件夹…",
            action: #selector(openFolderWithAgent),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let refreshItem = viewMenu.addItem(
            withTitle: "刷新状态",
            action: #selector(refreshStatus),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApplication.shared.mainMenu = mainMenu
    }
}
