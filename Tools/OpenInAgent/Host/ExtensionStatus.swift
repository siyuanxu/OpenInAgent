import AppKit
import FinderSync

struct OpenInAgentStatus {
    static let extensionIdentifier = "org.openinagent.OpenInAgent.FinderExtension"

    let extensionEnabled: Bool
    let extensionRunning: Bool
    let agents: [AgentAvailability]

    static func read() -> OpenInAgentStatus {
        let enabled = FIFinderSyncController.isExtensionEnabled
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: extensionIdentifier
        ).isEmpty

        return OpenInAgentStatus(
            extensionEnabled: enabled,
            extensionRunning: running,
            agents: AgentPreferences.shared.visibleAgents.map(AgentLauncher.availability)
        )
    }
}
