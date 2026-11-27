import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

struct AntigravityProjectRegistration {
    let title: String
    let created: Bool
}

enum AntigravityWorkspaceBridge {
    static let bundleIdentifier = "com.google.antigravity"
    static let accessPreference = "antigravityLocalProjectAccessAllowed"
    private static let launchLock = NSLock()

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func openWorkspace(_ directory: URL) throws -> AntigravityProjectRegistration {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw AgentLaunchError.unavailable("未检测到 Antigravity（反重力）桌面端。")
        }
        launchLock.lock()
        defer { launchLock.unlock() }
        try requestAccessIfNeeded()

        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }

        let certificates = try AntigravityBridgeSupport.bundledCertificates(app)
        let deadline = Date().addingTimeInterval(15)
        var client: AntigravityLocalClient?
        var projectIDs: [String] = []
        repeat {
            for server in try ownedServers(app) {
                // Read only this bundled child process's transient connection token.
                guard let token = try connectionToken(server) else { continue }
                for port in try listeningPorts(server) {
                    let candidate = AntigravityLocalClient(server: server, port: port,
                                                           token: token, certificates: certificates)
                    if let listing = try? candidate.request("ListProjects", body: [:]),
                       listing.isEmpty || listing["projectIds"] is [String] {
                        client = candidate
                        // Proto JSON omits an empty repeated field.
                        projectIDs = listing["projectIds"] as? [String] ?? []
                        break
                    }
                    candidate.close()
                }
                if client != nil { break }
            }
            if client != nil { break }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        guard let client else {
            throw AgentLaunchError.launchFailed("反重力本机项目服务尚未就绪，或当前版本不支持此接口。请打开桌面端并登录后重试。")
        }
        defer { client.close() }
        guard projectIDs.count <= 5000 else {
            throw AgentLaunchError.launchFailed("反重力项目数量超过本次安全读取上限，未创建新项目。")
        }

        let normalized = directory.standardizedFileURL.resolvingSymlinksInPath()
        var match: [String: Any]?
        for start in stride(from: 0, to: projectIDs.count, by: 50) {
            let ids = Array(projectIDs[start..<min(start + 50, projectIDs.count)])
            let response = try client.request("ReadProjects", body: ["ids": ids])
            let projects = try AntigravityBridgeSupport.projects(from: response, requestedIDs: ids)
            match = projects.first { AntigravityBridgeSupport.matches($0, directory: normalized) }
            if match != nil { break }
        }

        let identifier: String
        let title: String
        let created = match == nil
        if let match, let existingID = match["id"] as? String, !existingID.isEmpty {
            identifier = existingID
            title = match["name"] as? String ?? normalized.lastPathComponent
        } else {
            identifier = UUID().uuidString.lowercased()
            title = normalized.lastPathComponent.isEmpty ? normalized.path : normalized.lastPathComponent
            let project: [String: Any] = [
                "id": identifier, "name": title, "isWorkspaceOnly": false,
                "projectResources": ["resources": [["folderUri": normalized.absoluteString]]]
            ]
            // Do not change permission presets, workspace trust, or start a conversation.
            do {
                _ = try client.request("CreateProject", body: ["project": project])
            } catch {
                // A timed-out create may already have committed. Never issue a second create.
                guard let check = try? client.request("ReadProject", body: ["id": identifier]),
                      let saved = check["project"] as? [String: Any],
                      saved["id"] as? String == identifier,
                      AntigravityBridgeSupport.matches(saved, directory: normalized) else { throw error }
            }
            let check = try client.request("ReadProject", body: ["id": identifier])
            guard let saved = check["project"] as? [String: Any],
                  saved["id"] as? String == identifier,
                  AntigravityBridgeSupport.matches(saved, directory: normalized) else {
                throw AgentLaunchError.launchFailed("反重力项目已提交，但目录核对未通过；未切换到该项目。")
            }
        }
        var components = URLComponents()
        components.scheme = "antigravity"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "project", value: identifier)]
        guard let link = components.url else {
            throw AgentLaunchError.launchFailed("项目已准备好，但未能唤醒反重力桌面端。")
        }
        // Bind the deep link to the same verified installation, not the default scheme handler.
        let opened = AntigravityReply()
        let completion = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { _, error in
            opened.store(error == nil ? .success([:]) : .failure(AgentLaunchError.launchFailed("项目已准备好，但未能唤醒反重力桌面端。")))
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 10) == .success, let outcome = opened.take() else {
            throw AgentLaunchError.launchFailed("反重力打开项目超时，请重试。")
        }
        _ = try outcome.get()
        return AntigravityProjectRegistration(title: title, created: created)
    }

    static func revokeAccess() throws {
        let domain = AgentPreferences.preferencesDomain as CFString
        CFPreferencesSetValue(accessPreference as CFString, nil, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw AgentLaunchError.launchFailed("无法撤销反重力本机接入许可，请重试。")
        }
    }

    private static func requestAccessIfNeeded() throws {
        let domain = AgentPreferences.preferencesDomain as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if CFPreferencesCopyValue(accessPreference as CFString, domain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool == true { return }
        let ask = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许连接反重力的本机项目接口？"
            alert.informativeText = "OpenInAgent 会读取反重力本机进程的临时连接令牌，用于查询或创建所选文件夹的项目。令牌不保存、不上传，不读取聊天内容，不发送任务。你可在“显示设置…”中撤销。"
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }
        let allowed = Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
        guard allowed else { throw AgentLaunchError.cancelled }
        CFPreferencesSetValue(accessPreference as CFString, kCFBooleanTrue, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw AgentLaunchError.launchFailed("无法保存反重力本机项目访问许可。")
        }
    }

    private static func ownedServers(_ app: URL) throws -> [AntigravityOwnedServer] {
        let expected = app.appendingPathComponent("Contents/Resources/bin/language_server").standardizedFileURL.path
        var result: [AntigravityOwnedServer] = []
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where running.bundleURL?.standardizedFileURL == app.standardizedFileURL {
            var pending = [running.processIdentifier]
            var visited = Set<pid_t>()
            while let parent = pending.popLast(), visited.count < 100 {
                guard visited.insert(parent).inserted else { continue }
                let children = try run("/usr/bin/pgrep", ["-P", String(parent)], allowing: [0, 1])
                for item in children.split(whereSeparator: \.isNewline) {
                    guard let pid = pid_t(item) else { continue }
                    let path = try run("/bin/ps", ["-p", String(pid), "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard path.hasPrefix(app.path + "/Contents/") else { continue }
                    if path == expected {
                        result.append(AntigravityOwnedServer(pid: pid, root: running.processIdentifier,
                                                            executable: expected, appPath: app.path))
                    } else { pending.append(pid) }
                }
            }
        }
        return result
    }

    private static func connectionToken(_ server: AntigravityOwnedServer) throws -> String? {
        guard server.isOwned else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, server.pid]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0,
              length > 4, length <= 1_048_576 else { return nil }
        var bytes = Data(count: length)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let status = bytes.withUnsafeMutableBytes { ptr in
            sysctl(&mib, u_int(mib.count), ptr.baseAddress, &length, nil, 0)
        }
        guard status == 0, server.isOwned else { return nil }
        return AntigravityBridgeSupport.token(in: bytes.prefix(length), expectedExecutable: server.executable)
    }

    private static func listeningPorts(_ server: AntigravityOwnedServer) throws -> [Int] {
        guard server.isOwned else { return [] }
        let output = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(server.pid),
                                               "-iTCP", "-sTCP:LISTEN", "-Fn"], allowing: [0, 1])
        return AntigravityBridgeSupport.ports(in: output)
    }

    fileprivate static func run(_ executable: String, _ arguments: [String], allowing: [Int32] = [0]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowing.contains(process.terminationStatus), let text = String(data: data, encoding: .utf8) else {
            throw AgentLaunchError.launchFailed("无法核对反重力的本机进程。")
        }
        return text
    }
}

private struct AntigravityOwnedServer {
    let pid: pid_t
    let root: pid_t
    let executable: String
    let appPath: String

    var isOwned: Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityWorkspaceBridge.bundleIdentifier)
            .contains(where: { $0.processIdentifier == root && $0.bundleURL?.path == appPath }),
              let path = try? AntigravityWorkspaceBridge.run("/bin/ps", ["-p", String(pid), "-o", "comm="]),
              path.trimmingCharacters(in: .whitespacesAndNewlines) == executable else { return false }
        var current = pid
        for _ in 0..<20 {
            guard let text = try? AntigravityWorkspaceBridge.run("/bin/ps", ["-p", String(current), "-o", "ppid="]),
                  let parent = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            if parent == root { return true }
            if parent <= 1 || parent == current { return false }
            current = parent
        }
        return false
    }
}

enum AntigravityBridgeSupport {
    static func acceptsPinnedCertificate(_ leaf: SecCertificate, pins: [Data], now: Date = Date()) -> Bool {
        guard pins.contains(SecCertificateCopyData(leaf) as Data),
              let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName,
                  kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let before = (values[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? Double,
              let after = (values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? Double,
              before <= after, (before...after).contains(now.timeIntervalSinceReferenceDate),
              let names = (values[kSecOIDSubjectAltName as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]] else { return false }
        return names.contains { $0[kSecPropertyKeyLabel as String] as? String == "IP Address"
            && $0[kSecPropertyKeyValue as String] as? String == "127.0.0.1" }
    }

    static func projects(from response: [String: Any], requestedIDs: [String]) throws -> [[String: Any]] {
        func invalid() -> AgentLaunchError {
            .launchFailed("反重力项目列表读取不完整，未创建新项目。请稍后重试。")
        }
        for key in ["notFoundIds", "failedIds"] {
            if response[key] != nil && !(response[key] is [String]) { throw invalid() }
        }
        if response["projects"] != nil && !(response["projects"] is [[String: Any]]) { throw invalid() }
        guard (response["failedIds"] as? [String] ?? []).isEmpty else { throw invalid() }
        let projects = response["projects"] as? [[String: Any]] ?? []
        let ids = projects.compactMap { $0["id"] as? String }
        let notFound = response["notFoundIds"] as? [String] ?? []
        guard ids.count == projects.count, Set(ids).count == ids.count, !ids.contains(""),
              Set(ids).isDisjoint(with: notFound), Set(ids).union(notFound) == Set(requestedIDs) else { throw invalid() }
        return projects
    }

    static func ports(in output: String) -> [Int] {
        Array(Set(output.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            guard line.hasPrefix("n127.0.0.1:"),
                  let port = Int(line.dropFirst("n127.0.0.1:".count)), (1...65535).contains(port) else { return nil }
            return port
        })).sorted()
    }

    static func token(in data: Data, expectedExecutable: String) -> String? {
        guard data.count >= 5 else { return nil }
        let argc = data.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard (1...1024).contains(argc) else { return nil }
        var cursor = 4
        func string() -> String? {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(data: data[cursor..<end], encoding: .utf8)
        }
        guard string() == expectedExecutable else { return nil }
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { guard string() != nil else { return nil } }
        while cursor < data.count {
            guard let entry = string() else { return nil }
            let prefix = "ANTIGRAVITY_SERVER_CSRF_TOKEN="
            if entry.hasPrefix(prefix) {
                let token = String(entry.dropFirst(prefix.count))
                guard token.range(of: "^[A-Za-z0-9._~+/=-]{16,4096}$", options: .regularExpression) != nil else { return nil }
                return token
            }
        }
        return nil
    }

    static func matches(_ project: [String: Any], directory: URL) -> Bool {
        guard project["archived"] as? Bool != true,
              let id = project["id"] as? String, !id.isEmpty,
              let resources = (project["projectResources"] as? [String: Any])?["resources"] as? [[String: Any]],
              resources.count == 1 else { return false }
        let item = resources[0]
        guard let uri = item["folderUri"] as? String ?? (item["gitFolder"] as? [String: Any])?["folderUri"] as? String,
              let url = URL(string: uri), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path == directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func bundledCertificates(_ app: URL) throws -> [Data] {
        let file = try FileHandle(forReadingFrom: app.appendingPathComponent("Contents/Resources/app.asar"))
        defer { try? file.close() }
        func fail() -> AgentLaunchError { .launchFailed("无法读取反重力自带的本机服务证书；请更新反重力或 OpenInAgent。") }
        guard let header = try file.read(upToCount: 16), header.count == 16 else { throw fail() }
        func integer(_ index: Int) -> Int {
            header[index..<index + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        let headerBytes = integer(12)
        let base = 8 + integer(4)
        guard (2...8_388_608).contains(headerBytes), base >= 16 + headerBytes,
              let json = try file.read(upToCount: headerBytes), json.count == headerBytes,
              var node = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw fail() }
        for name in ["dist", "actuator", "pinnedLsCert.js"] {
            guard let next = (node["files"] as? [String: Any])?[name] as? [String: Any] else { throw fail() }
            node = next
        }
        guard node["unpacked"] as? Bool != true,
              let offsetText = node["offset"] as? String, let offset = UInt64(offsetText),
              let size = node["size"] as? Int, (1...65536).contains(size),
              offset < 100_000_000 else { throw fail() }
        try file.seek(toOffset: UInt64(base) + offset)
        guard let data = try file.read(upToCount: size), data.count == size,
              let source = String(data: data, encoding: .utf8) else { throw fail() }
        let regex = try NSRegularExpression(pattern: "-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]+)-----END CERTIFICATE-----")
        let certificates = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match -> Data? in
            guard let range = Range(match.range(at: 1), in: source),
                  let der = Data(base64Encoded: String(source[range]), options: .ignoreUnknownCharacters),
                  SecCertificateCreateWithData(nil, der as CFData) != nil else { return nil }
            return der
        }
        guard !certificates.isEmpty else { throw fail() }
        return certificates
    }
}

private final class AntigravityLocalClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let server: AntigravityOwnedServer
    private let port: Int
    private let token: String
    private let certificates: [Data]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(server: AntigravityOwnedServer, port: Int, token: String, certificates: [Data]) {
        self.server = server
        self.port = port
        self.token = token
        self.certificates = certificates
    }

    func close() { session.invalidateAndCancel() }

    func request(_ method: String, body: [String: Any]) throws -> [String: Any] {
        guard ["ListProjects", "ReadProjects", "ReadProject", "CreateProject"].contains(method), server.isOwned,
              let listening = try? AntigravityWorkspaceBridge.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(server.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]),
              AntigravityBridgeSupport.ports(in: listening).contains(port) else {
            throw AgentLaunchError.launchFailed("反重力本机服务进程已改变，请重试。")
        }
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        let reply = AntigravityReply()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let response = response as? HTTPURLResponse else {
                reply.store(.failure(AgentLaunchError.launchFailed("无法安全连接反重力本机项目服务。")))
                return
            }
            guard response.statusCode == 200, let data, data.count <= 8_388_608,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                reply.store(.failure(AgentLaunchError.launchFailed("反重力本机项目接口未成功响应（HTTP \(response.statusCode)）。")))
                return
            }
            reply.store(.success(object))
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 8) == .success, let outcome = reply.take() else {
            task.cancel()
            throw AgentLaunchError.launchFailed("反重力本机项目接口响应超时，请稍后重试。")
        }
        return try outcome.get()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
              let trust = challenge.protectionSpace.serverTrust, server.isOwned else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              AntigravityBridgeSupport.acceptsPinnedCertificate(leaf, pins: certificates) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // The app's bundled loopback certificate has no serverAuth EKU. Require
        // its exact DER, loopback SAN and current validity, then validate X.509.
        // No other certificate, remote host or expired bundled pin is accepted.
        let anchors = certificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class AntigravityReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String: Any], Error>?
    func store(_ value: Result<[String: Any], Error>) {
        lock.lock()
        defer { lock.unlock() }
        result = value
    }
    func take() -> Result<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
