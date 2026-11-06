import AppKit
import CryptoKit
import Foundation

struct DSHWorkspaceRegistration {
    let title: String
    let created: Bool
}

enum DSHWorkspaceBridge {
    private static let bundleIdentifier = "com.deepseek.dsh"
    private static let openURL = URL(string: "dsh://open")!
    private static let cookieDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/@deepseek-ai/dsh-desktop/Cookies")

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func openWorkspace(_ directory: URL) throws -> DSHWorkspaceRegistration {
        guard isInstalled else {
            throw AgentLaunchError.unavailable(
                "未检测到 DSH 桌面端（DeepSeek Harness）。请先安装 /Applications/DeepSeek Harness.app。"
            )
        }

        if runningApplications.isEmpty {
            guard NSWorkspace.shared.open(openURL) else {
                throw AgentLaunchError.launchFailed("无法启动 DSH 桌面端。")
            }
        }

        let deadline = Date().addingTimeInterval(12)
        var lastFailure: Error?
        repeat {
            do {
                let applications = runningApplications
                if !applications.isEmpty {
                    for port in try listeningPorts(for: applications) {
                        guard let cookie = cookie(for: port) else { continue }
                        do {
                            let registration = try createWorkspace(
                                directory,
                                port: port,
                                cookie: cookie
                            )
                            guard NSWorkspace.shared.open(openURL) else {
                                throw AgentLaunchError.launchFailed(
                                    "工作区已加入 DSH，但无法唤醒 DSH 桌面端。"
                                )
                            }
                            return registration
                        } catch {
                            lastFailure = error
                            if !isRetryable(error) {
                                throw error
                            }
                        }
                    }
                }
            } catch {
                lastFailure = error
                if !isRetryable(error) {
                    throw error
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline

        if let lastFailure {
            throw lastFailure
        }
        throw AgentLaunchError.launchFailed(
            "DSH 桌面端已启动，但工作区服务尚未就绪。请稍后重试。"
        )
    }

    private static var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
    }

    private static func listeningPorts(
        for applications: [NSRunningApplication]
    ) throws -> [Int] {
        let processIDs = try dshProcessIdentifiers(for: applications)
        guard !processIDs.isEmpty else { return [] }
        guard let output = try? run(
            executable: "/usr/sbin/lsof",
            arguments: [
                "-nP", "-a", "-p", processIDs.map(String.init).joined(separator: ","),
                "-iTCP", "-sTCP:LISTEN", "-Fpn"
            ]
        ) else { return [] }
        var ports: [Int] = []
        var currentProcessIsDSH = false
        for line in output.split(whereSeparator: \Character.isNewline) {
            let value = String(line)
            if value.hasPrefix("p"),
               let processID = Int32(value.dropFirst()) {
                currentProcessIsDSH = processIDs.contains(processID)
                continue
            }
            guard currentProcessIsDSH else { continue }
            guard value.hasPrefix("n127.0.0.1:") else { continue }
            if let port = Int(value.dropFirst("n127.0.0.1:".count)),
               !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    private static func dshProcessIdentifiers(
        for applications: [NSRunningApplication]
    ) throws -> Set<Int32> {
        let roots = Set(applications.map(\.processIdentifier))
        guard !roots.isEmpty else { return [] }
        let bundlePaths = Set(applications.compactMap {
            $0.bundleURL?.standardizedFileURL.path
        })
        var accepted = roots
        var pending = Array(roots)
        while let parent = pending.popLast() {
            let output = try run(
                executable: "/usr/bin/pgrep",
                arguments: ["-P", String(parent)],
                allowing: [0, 1]
            )
            for line in output.split(whereSeparator: \Character.isNewline) {
                guard let child = Int32(line), !accepted.contains(child) else {
                    continue
                }
                guard let command = try? run(
                    executable: "/bin/ps",
                    arguments: ["-o", "comm=", "-p", String(child)]
                ) else {
                    continue
                }
                let executablePath = URL(
                    fileURLWithPath: command.trimmingCharacters(in: .whitespacesAndNewlines)
                ).standardizedFileURL.path
                guard bundlePaths.contains(where: {
                    executablePath == $0 || executablePath.hasPrefix($0 + "/")
                }) else {
                    continue
                }
                accepted.insert(child)
                pending.append(child)
            }
        }
        return accepted
    }

    private static func cookie(for port: Int) -> (name: String, value: String)? {
        guard FileManager.default.isReadableFile(atPath: cookieDatabase.path) else {
            return nil
        }
        let separator = "\u{1F}"
        let name = expectedCookieName(for: port)
        let query = """
        SELECT name, value
        FROM cookies
        WHERE host_key = '127.0.0.1'
          AND name = '\(name)'
          AND value <> ''
        ORDER BY last_access_utc DESC
        LIMIT 1;
        """
        guard let output = try? run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-separator", separator, cookieDatabase.path, query]
        ) else {
            return nil
        }
        guard let line = output.split(whereSeparator: \Character.isNewline).first else {
            return nil
        }
        let fields = line.split(separator: Character(separator), maxSplits: 1)
        guard fields.count == 2, fields[0] == Substring(name) else { return nil }
        return (String(fields[0]), String(fields[1]))
    }

    private static func expectedCookieName(for port: Int) -> String {
        let authority = Data("127.0.0.1:\(port)".utf8)
        let digest = SHA256.hash(data: authority)
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dsh-auth-\(encoded)"
    }

    private static func createWorkspace(
        _ directory: URL,
        port: Int,
        cookie: (name: String, value: String)
    ) throws -> DSHWorkspaceRegistration {
        let requestID = UUID().uuidString.lowercased()
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": requestID,
            "method": "workspace/create",
            "payload": [
                "args": [
                    "request": ["path": directory.path]
                ]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/api/workspace/create")!
        )
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\(cookie.name)=\(cookie.value)",
            forHTTPHeaderField: "Cookie"
        )

        let response = try send(request)
        if response.statusCode == 401 {
            throw DSHBridgeRetryableError.authenticationPending
        }
        guard response.statusCode == 200 else {
            throw AgentLaunchError.launchFailed(
                "DSH 工作区服务返回了异常状态（HTTP \(response.statusCode)）。"
            )
        }
        return try decodeRegistration(response.data, requestID: requestID)
    }

    private static func decodeRegistration(
        _ data: Data,
        requestID: String
    ) throws -> DSHWorkspaceRegistration {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["type"] as? String == "server-response",
            root["rpcId"] as? String == requestID,
            let result = root["result"] as? [String: Any]
        else {
            throw AgentLaunchError.launchFailed("DSH 返回了无法识别的工作区响应。")
        }

        if result["ok"] as? Bool == false {
            let error = result["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "未知错误"
            throw AgentLaunchError.launchFailed("DSH 无法添加该工作区：\(message)")
        }
        guard
            result["ok"] as? Bool == true,
            let value = result["value"] as? [String: Any],
            let workspace = value["workspace"] as? [String: Any],
            let title = workspace["title"] as? String,
            let created = value["created"] as? Bool
        else {
            throw AgentLaunchError.launchFailed("DSH 返回的工作区信息不完整。")
        }
        return DSHWorkspaceRegistration(title: title, created: created)
    }

    private static func send(_ request: URLRequest) throws -> (data: Data, statusCode: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int?
        var responseError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseCode = (response as? HTTPURLResponse)?.statusCode
            responseError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw DSHBridgeRetryableError.servicePending
        }
        session.finishTasksAndInvalidate()
        if let responseError {
            throw DSHBridgeRetryableError.transport(responseError)
        }
        guard let responseData, let responseCode else {
            throw DSHBridgeRetryableError.servicePending
        }
        return (responseData, responseCode)
    }

    private static func run(
        executable: String,
        arguments: [String],
        allowing statuses: Set<Int32> = [0]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            finished.signal()
        }
        try process.run()
        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            throw DSHBridgeRetryableError.helperFailed
        }
        guard statuses.contains(process.terminationStatus) else {
            throw DSHBridgeRetryableError.helperFailed
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private static func isRetryable(_ error: Error) -> Bool {
        error is DSHBridgeRetryableError
    }
}

private enum DSHBridgeRetryableError: LocalizedError {
    case authenticationPending
    case cookiePending
    case helperFailed
    case servicePending
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .authenticationPending, .cookiePending:
            return "DSH 桌面端正在准备本机身份，请稍后重试。"
        case .helperFailed, .servicePending:
            return "DSH 桌面端的工作区服务尚未就绪，请稍后重试。"
        case .transport(let error):
            return "连接 DSH 桌面端失败：\(error.localizedDescription)"
        }
    }
}
