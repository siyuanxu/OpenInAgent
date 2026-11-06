import AppKit
import Foundation

struct AgentAvailability {
    let kind: AgentKind
    let isAvailable: Bool
    let detail: String
}

enum AgentLaunchError: LocalizedError {
    case unavailable(String)
    case invalidURL(String)
    case launchFailed(String)
    case automationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message),
             .invalidURL(let message),
             .launchFailed(let message),
             .automationFailed(let message):
            return message
        }
    }
}

enum AgentLauncher {
    static func availability(for kind: AgentKind) -> AgentAvailability {
        switch kind {
        case .codex:
            let available = applicationCanOpen(scheme: "codex", host: "new")
            return AgentAvailability(
                kind: kind,
                isAvailable: available,
                detail: available ? "已安装，可直接打开项目目录" : "未检测到 Codex 桌面端"
            )
        case .dsh:
            let available = DSHWorkspaceBridge.isInstalled
            return AgentAvailability(
                kind: kind,
                isAvailable: available,
                detail: available
                    ? "已安装，可把目录加入工作区列表并唤醒桌面端"
                    : "未检测到 DSH 桌面端（DeepSeek Harness）"
            )
        case .zcode:
            let available = applicationCanOpen(scheme: "zcode", host: "workspace")
            return AgentAvailability(
                kind: kind,
                isAvailable: available,
                detail: available ? "已安装，可直接打开工作区" : "未检测到 ZCode"
            )
        case .hermes:
            let path = executable(named: "hermes")
            return AgentAvailability(
                kind: kind,
                isAvailable: path != nil,
                detail: path == nil
                    ? "未检测到 Hermes CLI"
                    : "已安装，通过 Hermes Desktop 打开目录"
            )
        case .kimi:
            let path = executable(named: "kimi")
            return AgentAvailability(
                kind: kind,
                isAvailable: path != nil,
                detail: path == nil
                    ? "未安装 Kimi Code CLI"
                    : "已安装，在 Terminal 中从项目目录启动"
            )
        case .terminal:
            let available = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal"
            ) != nil
            return AgentAvailability(
                kind: kind,
                isAvailable: available,
                detail: available ? "macOS 自带终端，直接进入所选目录" : "未找到系统终端 Terminal"
            )
        }
    }

    @discardableResult
    static func launch(_ kind: AgentKind, directory: URL) throws -> String {
        let normalized = directory.standardizedFileURL
        let values = try? normalized.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw AgentLaunchError.launchFailed("目标不是可访问的文件夹：\(normalized.path)")
        }

        switch kind {
        case .codex:
            try openURL(
                scheme: "codex",
                host: "new",
                queryItems: [URLQueryItem(name: "path", value: normalized.path)],
                unavailableMessage: "无法打开 Codex。请确认 Codex 桌面端已安装。"
            )
            return "已把“\(normalized.lastPathComponent)”交给 Codex。"

        case .dsh:
            let result = try DSHWorkspaceBridge.openWorkspace(normalized)
            return result.created
                ? "已把“\(result.title)”加入 DSH 桌面端工作区列表并唤醒 DSH；请在左侧点一下该工作区开始会话。"
                : "DSH 桌面端已有工作区“\(result.title)”；已唤醒 DSH，请在左侧点一下该工作区。"

        case .zcode:
            try openURL(
                scheme: "zcode",
                host: "workspace",
                path: "/open",
                queryItems: [URLQueryItem(name: "path", value: normalized.path)],
                unavailableMessage: "无法打开 ZCode。请确认 ZCode 已安装。"
            )
            return "已把“\(normalized.lastPathComponent)”交给 ZCode。"

        case .hermes:
            guard let executable = executable(named: "hermes") else {
                throw AgentLaunchError.unavailable(
                    "未检测到 Hermes CLI。OpenInAgent 只使用 Hermes 官方的 desktop --cwd 入口，以确保目录真的传入。"
                )
            }
            try runDetached(
                executable: executable,
                arguments: ["desktop", "--cwd", normalized.path]
            )
            return "已通过 Hermes Desktop 打开“\(normalized.lastPathComponent)”。"

        case .kimi:
            guard let executable = executable(named: "kimi") else {
                throw AgentLaunchError.unavailable(
                    "本机尚未安装 Kimi Code CLI。安装后，OpenInAgent 会在 Terminal 中从所选项目目录启动它。"
                )
            }
            try launchInTerminal(
                executable: executable,
                workingDirectory: normalized
            )
            return "已在 Terminal 中用 Kimi 打开“\(normalized.lastPathComponent)”。"

        case .terminal:
            try openDirectoryInSystemTerminal(normalized)
            return "已在系统终端中打开“\(normalized.lastPathComponent)”。"
        }
    }

    private static func openDirectoryInSystemTerminal(_ directory: URL) throws {
        // Terminal accepts directory documents. Pass the path as an argument,
        // without interpreting it as shell code or requiring Apple Events access.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.apple.Terminal", directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AgentLaunchError.launchFailed("无法启动系统终端：\(error.localizedDescription)")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AgentLaunchError.launchFailed(
                detail.isEmpty ? "系统终端未能打开所选目录。" : "系统终端未能打开所选目录：\(detail)"
            )
        }
    }

    private static func applicationCanOpen(scheme: String, host: String) -> Bool {
        guard let url = URL(string: "\(scheme)://\(host)") else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    private static func openURL(
        scheme: String,
        host: String,
        path: String = "",
        queryItems: [URLQueryItem],
        unavailableMessage: String
    ) throws {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AgentLaunchError.invalidURL("无法构造 \(scheme) 项目链接。")
        }
        guard NSWorkspace.shared.open(url) else {
            throw AgentLaunchError.launchFailed(unavailableMessage)
        }
    }

    private static func executable(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.kimi-code/bin",
            "\(home)/.local/share/kimi/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        var seen = Set<String>()
        for directory in commonPaths + environmentPaths where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func runDetached(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AgentLaunchError.launchFailed(
                "无法启动 \(executable.lastPathComponent)：\(error.localizedDescription)"
            )
        }
    }

    private static func launchInTerminal(
        executable: URL,
        workingDirectory: URL
    ) throws {
        let command = "cd \(shellQuoted(workingDirectory.path)) && \(shellQuoted(executable.path))"
        let scriptSource = """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(command))
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            throw AgentLaunchError.automationFailed("无法创建 Terminal 启动指令。")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Terminal 自动化被系统拒绝。"
            throw AgentLaunchError.automationFailed(message)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
