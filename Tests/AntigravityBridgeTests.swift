import Foundation
import Security

@main
enum AntigravityBridgeTests {
    static func main() throws {
        // Public certificate generated only for tests; no private key is shipped.
        let certificateData = Data(base64Encoded: "MIIC3DCCAcSgAwIBAgIJAIcJQzckCgG0MA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGE9wZW5JbkFnZW50IHRlc3QgZml4dHVyZTAeFw0yNjExMjcwMTU3NDlaFw0yNjExMjkwMTU3NDlaMCMxITAfBgNVBAMMGE9wZW5JbkFnZW50IHRlc3QgZml4dHVyZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANC7hWPzdgoKPanrjiVG43ukseOhCQCHLJXa7HuUMCI8ajySg78u0f/Vc5jTyzBoc2SEFa/1kTkIY+fa5KPRSpTaWlujgduSOmk9xUoQEIEdo1yEvNtk7A3FNlKBPw0F35xxr/YoU3GGAfAbxQru+yltmdkoORfaA4U2MP9+sviBendGtERIwIg3bvXClhdbDHsi2edBs4UIPNkTbYzPZ5cmW416CCzAedqfGS1vJbY8XiOa2KBM896ka6vFnvjqTyZobqR0U+t+IvPrJAUbHstDaCm8CLmi8XpMF7iLWawIJvfLU2MW12vy2qoaXPduFQnVDly8FXsJ1Th6Ahv7xt0CAwEAAaMTMBEwDwYDVR0RBAgwBocEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAxglEovM6yA9UanrQ4+bzb7dLW12Dq6pfkb4nX9/OL9PfsfgM4gKbENEjRDu4m8IDMTAuZ2CZSmWJg+LQaJo4xKIq7wuBHus9x6NR7h0NMzGaV+OVwRH5rU17WGwjByyyME4xd4CviVxP2AIPLKnFyiB51S1/xqtYUNdWjQZ/8lIISwqqNZ24VvGJF/dRr5BQ1XROF3it7BUpECCliQQsTAtIKy3irx4NThIwKpvqrGIx4SwkOmp1LZdGz/LtZbcH4pYT0F2CJUGogyG4aKcBH8IPBV1ah99jaYzLbGK32DCxA86nT6IPVD0F5Wamn+livf7IN7XXQ2iJznigurybZg==")!
        let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)!
        let properties = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil)! as NSDictionary
        let before = (properties[kSecOIDX509V1ValidityNotBefore] as! NSDictionary)[kSecPropertyKeyValue] as! Double
        let after = (properties[kSecOIDX509V1ValidityNotAfter] as! NSDictionary)[kSecPropertyKeyValue] as! Double
        precondition(AntigravityBridgeSupport.acceptsPinnedCertificate(certificate, pins: [certificateData], now: Date(timeIntervalSinceReferenceDate: before + 60)))
        precondition(!AntigravityBridgeSupport.acceptsPinnedCertificate(certificate, pins: [Data([1, 2, 3])], now: Date(timeIntervalSinceReferenceDate: before + 60)))
        precondition(!AntigravityBridgeSupport.acceptsPinnedCertificate(certificate, pins: [certificateData], now: Date(timeIntervalSinceReferenceDate: before - 1)))
        precondition(!AntigravityBridgeSupport.acceptsPinnedCertificate(certificate, pins: [certificateData], now: Date(timeIntervalSinceReferenceDate: after + 1)))
        let executable = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        let fixtureToken = "fixture-token-0123456789"
        func processData(args: [String], environment: [String], path: String = executable) -> Data {
            var argc = UInt32(args.count).littleEndian
            var data = withUnsafeBytes(of: &argc) { Data($0) }
            data.append(Data((path + "\0\0\0").utf8))
            for value in args + environment { data.append(Data((value + "\0").utf8)) }
            return data
        }
        let valid = processData(args: [executable, "--standalone"], environment: [
            "PATH=/usr/bin", "ANTIGRAVITY_SERVER_CSRF_TOKEN=\(fixtureToken)", "OTHER=value"
        ])
        precondition(AntigravityBridgeSupport.token(in: valid, expectedExecutable: executable) == fixtureToken)
        precondition(AntigravityBridgeSupport.token(in: valid, expectedExecutable: executable + ".other") == nil)
        precondition(AntigravityBridgeSupport.token(in: Data([0, 1, 2]), expectedExecutable: executable) == nil)
        let forgedArgument = processData(args: [executable, "ANTIGRAVITY_SERVER_CSRF_TOKEN=\(fixtureToken)"], environment: [])
        precondition(AntigravityBridgeSupport.token(in: forgedArgument, expectedExecutable: executable) == nil)
        for value in ["short", "abc\r\nInjected: header", ""] {
            let raw = processData(args: [executable], environment: ["ANTIGRAVITY_SERVER_CSRF_TOKEN=\(value)"])
            precondition(AntigravityBridgeSupport.token(in: raw, expectedExecutable: executable) == nil)
        }
        let ports = AntigravityBridgeSupport.ports(in: "n127.0.0.1:1234\nn*:4567\nn192.0.2.1:1234\nn127.0.0.1:65536\nn127.0.0.1:0\nn127.0.0.1:1234\nn127.0.0.1:9876")
        precondition(ports == [1234, 9876])
        for response: [String: Any] in [[:], ["projects": "invalid"], ["projects": [["id": "other"]]],
                                        ["projects": [["id": "a"]]], ["failedIds": ["a"]],
                                        ["projects": [["id": "a"], ["id": "a"]]]] {
            do {
                _ = try AntigravityBridgeSupport.projects(from: response, requestedIDs: ["a", "b"])
                preconditionFailure("Incomplete project response must fail")
            } catch { }
        }
        let complete = try AntigravityBridgeSupport.projects(from: ["projects": [["id": "a"]], "notFoundIds": ["b"]], requestedIDs: ["a", "b"])
        precondition(complete.count == 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("中文 空格 & 'quote' # ? %", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        func project(_ resources: [[String: Any]], archived: Bool = false) -> [String: Any] {
            ["id": "fixture-project", "archived": archived, "projectResources": ["resources": resources]]
        }
        precondition(AntigravityBridgeSupport.matches(project([["folderUri": folder.absoluteString]]), directory: folder))
        precondition(AntigravityBridgeSupport.matches(project([["folderUri": alias.absoluteString]]), directory: folder))
        precondition(AntigravityBridgeSupport.matches(project([["gitFolder": ["folderUri": folder.absoluteString]]]), directory: folder))
        precondition(!AntigravityBridgeSupport.matches(project([["folderUri": folder.absoluteString]], archived: true), directory: folder))
        precondition(!AntigravityBridgeSupport.matches(project([["folderUri": folder.absoluteString], ["folderUri": root.absoluteString]]), directory: folder))
        precondition(!AntigravityBridgeSupport.matches(project([["folderUri": root.absoluteString]]), directory: folder))
        precondition(!AntigravityBridgeSupport.matches(project([["folderUri": "https://example.com/test"]]), directory: folder))
        precondition(!AntigravityBridgeSupport.matches(project([["folderUri": "file://remote-host" + folder.path]]), directory: folder))
        print("PASS: exact certificate pin and validity checks, environment-only token parsing, header injection rejection, exact loopback ports, incomplete project response rejection, directory URI encoding, aliases, git folders, archived and multi-folder exclusion")
    }
}
