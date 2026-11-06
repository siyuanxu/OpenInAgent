import AppKit

final class SettingsWindowController: NSWindowController {
    private var checkboxes: [AgentKind: NSButton] = [:]
    private let saveStatus = NSTextField(wrappingLabelWithString: "")
    var onChange: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenInAgent · 显示设置"
        window.center()
        super.init(window: window)
        buildInterface()
        reloadSelection()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        reloadSelection()
        super.showWindow(sender)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "显示哪些入口")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString:
            "勾选要在 Finder 菜单和 OpenInAgent 打开方式中显示的项目。"
        )
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        for kind in AgentKind.allCases {
            let checkbox = NSButton(
                checkboxWithTitle: kind.displayName,
                target: self,
                action: #selector(selectionChanged(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            checkboxes[kind] = checkbox
            stack.addArrangedSubview(checkbox)
        }
        saveStatus.font = .systemFont(ofSize: 12)
        saveStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(saveStatus)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saveStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func reloadSelection() {
        let enabled = Set(AgentPreferences.shared.visibleAgents)
        for (kind, checkbox) in checkboxes {
            checkbox.state = enabled.contains(kind) ? .on : .off
        }
        saveStatus.stringValue = "设置自动保存，下次展开 Finder 菜单即可生效。"
        saveStatus.textColor = .secondaryLabelColor
    }

    @objc private func selectionChanged(_ sender: NSButton) {
        let enabled = AgentKind.allCases.filter { checkboxes[$0]?.state == .on }
        do {
            try AgentPreferences.shared.save(enabled)
            saveStatus.stringValue = enabled.isEmpty
                ? "已隐藏所有打开入口，仍可从“显示设置…”重新启用。"
                : "已保存，下次展开 Finder 菜单即可生效。"
            saveStatus.textColor = .secondaryLabelColor
            onChange?()
        } catch {
            reloadSelection()
            saveStatus.stringValue = "保存失败：\(error.localizedDescription)"
            saveStatus.textColor = .systemRed
        }
    }
}
