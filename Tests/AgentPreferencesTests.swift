import Foundation
import CoreFoundation

@main
enum AgentPreferencesTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "read" {
            let actual = AgentPreferences(domain: arguments[2]).visibleAgents.map(\.rawValue)
            precondition(actual.joined(separator: ",") == arguments[3])
            return
        }

        let domain = "org.openinagent.tests." + UUID().uuidString
        let preferences = AgentPreferences(domain: domain)
        defer {
            CFPreferencesSetValue(AgentPreferences.visibleAgentsKey as CFString, nil,
                                  domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        precondition(preferences.visibleAgents == [.codex, .dsh, .terminal])
        try preferences.save([.terminal, .hermes, .hermes])
        precondition(preferences.visibleAgents == [.hermes, .terminal])
        try readInNewProcess(domain, expected: "hermes,terminal")
        try preferences.save([])
        try readInNewProcess(domain, expected: "")
        CFPreferencesSetValue(AgentPreferences.visibleAgentsKey as CFString,
                              ["kimi", "unknown", "codex", "kimi"] as CFArray,
                              domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        precondition(preferences.visibleAgents == [.codex, .kimi])
        try preferences.save(AgentPreferences.defaultVisibleAgents)
        try readInNewProcess(domain, expected: "codex,dsh,terminal")
        print("PASS: defaults, deduplication, independent process, empty selection, unknown identifiers, restore")
    }

    private static func readInNewProcess(_ domain: String, expected: String) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["read", domain, expected]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
    }
}
