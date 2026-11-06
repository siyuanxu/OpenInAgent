import Foundation
import CoreFoundation

enum AgentKind: String, CaseIterable {
    case codex
    case dsh
    case hermes
    case zcode
    case kimi
    case terminal

    var launchesInBackground: Bool {
        self == .dsh || self == .terminal
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .dsh: return "DSH"
        case .hermes: return "Hermes"
        case .zcode: return "ZCode"
        case .kimi: return "Kimi"
        case .terminal: return "终端（Terminal）"
        }
    }

    var toolbarTitle: String {
        self == .terminal ? "在终端中打开" : displayName
    }

    var contextMenuTitle: String {
        self == .terminal ? "在终端中打开" : "在 \(displayName) 中打开"
    }
}

struct AgentPreferences {
    // The sandboxed extension has read-only access to this one preference domain.
    // This does not depend on a developer's signing identity or Team ID.
    static let preferencesDomain = "org.openinagent.OpenInAgent"
    static let visibleAgentsKey = "visibleAgentIdentifiers"
    static let defaultVisibleAgents: [AgentKind] = [.codex, .dsh, .terminal]
    static let shared = AgentPreferences(domain: preferencesDomain)

    let domain: String

    var visibleAgents: [AgentKind] {
        // Merge persisted changes made by the host before building each menu.
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let identifiers = CFPreferencesCopyValue(
            Self.visibleAgentsKey as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] else {
            return Self.defaultVisibleAgents
        }
        let enabled = Set(identifiers)
        // An explicitly empty selection must stay empty.
        return AgentKind.allCases.filter { enabled.contains($0.rawValue) }
    }

    func save(_ agents: [AgentKind]) throws {
        let enabled = Set(agents)
        let identifiers = AgentKind.allCases.filter { enabled.contains($0) }.map(\.rawValue)
        CFPreferencesSetValue(
            Self.visibleAgentsKey as CFString,
            identifiers as CFArray,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) else {
            throw NSError(
                domain: "OpenInAgent.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法保存显示设置，请检查用户偏好设置的访问权限。"]
            )
        }
    }
}
