import Foundation

/// One provider can expose several surfaces with different evidence and
/// control boundaries. Profiles describe those surfaces without introducing a
/// public plugin API or granting capabilities to a concrete session.
enum IntegrationSurfaceID: String, Codable, Equatable, CaseIterable {
    case process
    case claudeCLI = "claude.cli"
    case codexCLI = "codex.cli"
    case codexDesktop = "codex.desktop"
    case codexManaged = "codex.managed"
    case openCodeTUI = "opencode.tui-http"
    case openCodeDesktop = "opencode.desktop"
    case deepSeekWeb = "deepseek.web"
    case copilotCLI = "copilot.cli"
    case kimiCLI = "kimi.cli"
    case grokCLI = "grok.cli"
    case mistralCLI = "mistral.cli"
    case geminiCLI = "gemini.cli"
    case qwenCLI = "qwen.cli"
    case cursorCLI = "cursor.cli"
    case cursorDesktop = "cursor.desktop"
    case workBuddyDesktop = "workbuddy.desktop"
    case experimentalLocal = "experimental.local"

    var providerKind: AgentKind? {
        switch self {
        case .claudeCLI: return .claude
        case .codexCLI, .codexDesktop, .codexManaged: return .codex
        case .openCodeTUI, .openCodeDesktop: return .opencode
        case .deepSeekWeb: return .deepseek
        case .copilotCLI: return .copilot
        case .kimiCLI: return .kimi
        case .grokCLI: return .grok
        case .mistralCLI: return .mistral
        case .geminiCLI: return .gemini
        case .qwenCLI: return .qwen
        case .cursorCLI, .cursorDesktop: return .cursorAgent
        case .workBuddyDesktop: return .workbuddy
        case .process, .experimentalLocal: return nil
        }
    }
}

enum IntegrationControlPolicy: String, Equatable {
    case none
    case labs
    case validatedLocalAPI
    case managedProvider
}

enum IntegrationDegradationPolicy: String, Equatable {
    case processOnly
    case stale
    case incompatible
}

struct IntegrationProfile: Equatable {
    let id: IntegrationSurfaceID
    let supportTier: ProviderSupportTier
    let phaseAuthority: ObservationAuthority?
    let attentionAuthority: ObservationAuthority?
    let completionAuthority: ObservationAuthority?
    let capabilities: AgentCapabilities
    let controlPolicy: IntegrationControlPolicy
    let supportedVersions: String
    let degradationPolicy: IntegrationDegradationPolicy
    let readerBudget: TimeInterval
    let stalledAfter: TimeInterval
    let reconciliationGrace: TimeInterval

    func canAssertCompletion(authority: ObservationAuthority) -> Bool {
        (completionAuthority == authority || (id == .codexManaged && authority == .officialLocalStore))
            && capabilities.contains(.observeCompletion)
    }

    func canAssertAttention(authority: ObservationAuthority) -> Bool {
        attentionAuthority == authority && capabilities.contains(.observeAttention)
    }
}

enum IntegrationProfiles {
    static func profile(for surface: IntegrationSurfaceID, kind: AgentKind) -> IntegrationProfile {
        let observation: AgentCapabilities = [
            .observeProcess, .observeSession, .observeTask, .observeStep,
            .providerReturn,
        ]
        let terminal = observation.union(.exactReturn)

        switch surface {
        case .claudeCLI:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore,
                attentionAuthority: .officialLive,
                completionAuthority: nil,
                capabilities: terminal.union(.observeAttention),
                controlPolicy: .labs,
                supportedVersions: "Current Claude Code session registry and transcript schema",
                degradationPolicy: .processOnly,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .codexCLI, .codexDesktop:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore,
                attentionAuthority: nil,
                completionAuthority: .officialLocalStore,
                capabilities: terminal.union(.observeCompletion),
                controlPolicy: .none,
                supportedVersions: "Current Codex rollout schema",
                degradationPolicy: .processOnly,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .codexManaged:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLive,
                attentionAuthority: .officialLive,
                completionAuthority: .officialLive,
                capabilities: observation.union([
                    .observeCompletion, .observeAttention, .exactReturn, .reply, .stop,
                ]),
                controlPolicy: .managedProvider,
                supportedVersions: "Bundled Codex app-server protocol",
                degradationPolicy: .stale,
                readerBudget: 1.0,
                stalledAfter: 3 * 60,
                reconciliationGrace: 12
            )
        case .openCodeTUI:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLive,
                attentionAuthority: .officialLive,
                completionAuthority: .officialLive,
                capabilities: terminal.union([
                    .observeAttention, .observeCompletion, .reply, .approve,
                ]),
                controlPolicy: .validatedLocalAPI,
                supportedVersions: "OpenCode 1.18.x loopback API",
                degradationPolicy: .processOnly,
                readerBudget: 0.8,
                stalledAfter: 3 * 60,
                reconciliationGrace: 12
            )
        case .openCodeDesktop:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore,
                attentionAuthority: nil,
                completionAuthority: nil,
                capabilities: observation,
                controlPolicy: .none,
                supportedVersions: "Current OpenCode Desktop local store",
                degradationPolicy: .processOnly,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .deepSeekWeb:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .versionedObserver,
                attentionAuthority: nil,
                completionAuthority: nil,
                capabilities: observation,
                controlPolicy: .none,
                supportedVersions: "dsh-v0.1.2-alpha.5 / db6bdc3",
                degradationPolicy: .incompatible,
                readerBudget: 0.5,
                stalledAfter: 3 * 60,
                reconciliationGrace: 12
            )
        case .copilotCLI:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore,
                attentionAuthority: nil,
                completionAuthority: .officialLocalStore,
                capabilities: observation.union(.observeCompletion),
                controlPolicy: .none,
                supportedVersions: "Copilot CLI 1.0.83; open-session schema 1",
                degradationPolicy: .stale,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .kimiCLI:
            return .init(
                id: surface,
                supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore,
                attentionAuthority: nil,
                completionAuthority: .officialLocalStore,
                capabilities: observation.union(.observeCompletion),
                controlPolicy: .none,
                supportedVersions: "Kimi Code 0.41.0; main-agent wire 1.5",
                degradationPolicy: .stale,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .grokCLI:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .officialLocalStore, attentionAuthority: .officialLocalStore,
                completionAuthority: .officialLocalStore,
                capabilities: terminal.union([.observeCompletion, .observeAttention]),
                controlPolicy: .none, supportedVersions: "Grok Build event schema 1.0",
                degradationPolicy: .stale, readerBudget: 0.8,
                stalledAfter: 10 * 60, reconciliationGrace: 20)
        case .mistralCLI:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .versionedObserver, attentionAuthority: nil, completionAuthority: nil,
                capabilities: terminal, controlPolicy: .none, supportedVersions: "Mistral Vibe 2.25.0 tool hooks",
                degradationPolicy: .stale, readerBudget: 0.8, stalledAfter: 10 * 60, reconciliationGrace: 20)
        case .cursorDesktop:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .versionedObserver, attentionAuthority: nil, completionAuthority: nil,
                capabilities: observation, controlPolicy: .none,
                supportedVersions: "Cursor 3.20.17 rendered Agents panes (Accessibility)",
                degradationPolicy: .stale, readerBudget: 0.8, stalledAfter: 10 * 60, reconciliationGrace: 20)
        case .cursorCLI:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: nil, attentionAuthority: nil, completionAuthority: nil,
                capabilities: terminal, controlPolicy: .none,
                supportedVersions: "Cursor CLI 2026.09.02-c22c1a3 local transcript and observation hooks",
                degradationPolicy: .processOnly, readerBudget: 0.8, stalledAfter: 180, reconciliationGrace: 20)
        case .workBuddyDesktop:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .versionedObserver, attentionAuthority: nil, completionAuthority: nil,
                capabilities: terminal, controlPolicy: .none,
                supportedVersions: "WorkBuddy 5.5.3 / bundled CodeBuddy 2.137.1 observation hooks",
                degradationPolicy: .stale, readerBudget: 0.8, stalledAfter: 180, reconciliationGrace: 20)
        case .geminiCLI, .qwenCLI:
            return .init(
                id: surface, supportTier: SupportRegistry.tier(surface),
                phaseAuthority: .versionedObserver, attentionAuthority: nil, completionAuthority: nil,
                capabilities: terminal, controlPolicy: .none,
                supportedVersions: surface == .geminiCLI ? "Gemini CLI 0.58.0 hooks" : "Qwen Code 0.23.0 hooks",
                degradationPolicy: .stale, readerBudget: 0.8, stalledAfter: 180, reconciliationGrace: 20)
        case .experimentalLocal:
            return .init(
                id: surface,
                supportTier: .experimental,
                phaseAuthority: .officialLocalStore,
                attentionAuthority: nil,
                completionAuthority: nil,
                capabilities: terminal.subtracting(.observeCompletion),
                controlPolicy: .none,
                supportedVersions: "Best-effort local observation",
                degradationPolicy: .processOnly,
                readerBudget: 0.8,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        case .process:
            return .init(
                id: surface,
                supportTier: .experimental,
                phaseAuthority: .processHeuristic,
                attentionAuthority: nil,
                completionAuthority: nil,
                capabilities: [.observeProcess, .providerReturn],
                controlPolicy: .none,
                supportedVersions: "Any detectable local process",
                degradationPolicy: .processOnly,
                readerBudget: 0.2,
                stalledAfter: 10 * 60,
                reconciliationGrace: 20
            )
        }
    }
}
