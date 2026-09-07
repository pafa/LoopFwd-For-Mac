import Foundation

/// The preview's single release allowlist. Retained readers are not necessarily
/// shipped integrations; neither a badge nor a brand grants control authority.
enum SupportRegistry {
    static let shippedKinds: [AgentKind] = [
        .codex, .opencode, .copilot, .claude, .gemini, .qwen, .kimi, .grok,
    ]
    static let deferredKinds = Set(AgentKind.allCases).subtracting(shippedKinds)

    /// Basic real-task evidence, not every environment or every capability:
    /// Codex Desktop monitoring/return, OpenCode HTTP lifecycle/questions,
    /// Copilot CLI running/recovery/stop and explicit Autopilot completion.
    static let testedSurfaces: Set<IntegrationSurfaceID> = [.codexDesktop, .openCodeTUI, .copilotCLI]

    static func tier(_ kind: AgentKind) -> ProviderSupportTier {
        testedSurfaces.contains { $0.providerKind == kind } ? .previewTested : .experimental
    }

    static func tier(_ surface: IntegrationSurfaceID) -> ProviderSupportTier {
        testedSurfaces.contains(surface) ? .previewTested : .experimental
    }

    static var summary: String {
        L10n.format("%d integrations · %d preview-tested surfaces", shippedKinds.count, testedSurfaces.count)
    }
}
