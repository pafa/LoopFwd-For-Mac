import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Diagnostics

struct DiagnosticsPane: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var scanUpdates = AgentMonitor.shared.diagnosticsUpdates
    @ObservedObject private var operations = OperationalDiagnostics.shared
    @State private var copied = false
    @State private var layoutTrace = IslandDebugTrace.snapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if IslandDebugTrace.enabled {
                SSection(title: "Layout trace", footer: "Local geometry only. Updates when you click Refresh.") {
                    SRow(title: "Layout trace") {
                        Button(L10n.string("Refresh")) { layoutTrace = IslandDebugTrace.snapshot() }
                    }
                    Text(layoutTrace.suffix(32).joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            SSection(
                title: "Scanner",
                footer:
                    "This report omits prompts, messages, credentials and full paths. Review it before sharing in a LoopFwd bug report."
            ) {
                SRow(title: "Last successful scan", subtitle: scanSubtitle) {
                    Button(L10n.string("Refresh")) { monitor.scanNow() }
                }
                SDiv()
                SRow(
                    title: "Sanitized diagnostics",
                    subtitle: L10n.format("%d observed sessions", monitor.agents.count)
                ) {
                    Button(L10n.string(copied ? "Copied" : "Copy Report")) { copyReport() }
                }
                if let decision = operations.lastNotificationDecision {
                    SDiv()
                    SRow(title: "Last notification decision", subtitle: decision) { EmptyView() }
                }
                if let failure = operations.lastReturnFailure {
                    SDiv()
                    SRow(title: "Last return failure", subtitle: failure) { EmptyView() }
                }
                if let failure = operations.lastControlFailure {
                    SDiv()
                    SRow(title: "Last control failure", subtitle: failure) { EmptyView() }
                }
            }

            SSection(title: "Provider sources") {
                ForEach(Array(SupportRegistry.shippedKinds.enumerated()), id: \.element.rawValue) { index, kind in
                    if index > 0 { SDiv() }
                    SRow(title: kind.displayName, subtitle: providerSummary(kind)) {
                        Text(kind.supportTier.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scanSubtitle: String {
        guard let date = monitor.lastSuccessfulScanAt else { return L10n.string("No completed scan yet") }
        let relative = L10n.relativeTime(date)
        return "\(relative) · \(Int(monitor.lastScanDuration * 1000)) ms"
    }

    private func providerSummary(_ kind: AgentKind) -> String {
        let sessions = monitor.agents.filter { $0.kind == kind }
        let reads = monitor.surfaceDiagnostics.filter { $0.key.providerKind == kind }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        if !reads.isEmpty {
            return reads.map { surface, read in
                let health = L10n.string(Self.sourceHealthKey(for: read.outcome))
                let lastSuccess = read.lastSuccessfulAt.map { L10n.relativeTime($0) } ?? L10n.string("Never")
                let lastComplete = L10n.format("Last complete read: %@", lastSuccess)
                let observed = Self.observedVersions(sessions.filter { $0.surfaceID == surface })
                let version = L10n.format(
                    "Observed version: %@", observed == "unknown" ? L10n.string("Unknown") : observed)
                let reason = read.errorCategory.map { " · " + L10n.string($0) } ?? ""
                return
                    "\(surface.rawValue) · \(health) · \(lastComplete) · \(Int(read.duration * 1000)) ms\(reason)\n\(version)"
            }.joined(separator: "\n")
        }
        guard !sessions.isEmpty else {
            return L10n.string(
                kind.softwareAvailable
                    ? "No active session · installed, not verified" : "No active session · software not found")
        }
        let modes = Set(sessions.map(\.observation.mode.rawValue)).sorted().joined(separator: ", ")
        let phases = Set(sessions.map { $0.status.label }).sorted().joined(separator: ", ")
        let authorities = Set(sessions.map(\.observation.authority.shortLabel)).sorted()
            .joined(separator: ", ")
        let surfaces = Set(sessions.map(\.surfaceID.rawValue)).sorted().joined(separator: ", ")
        let capabilities = Set(sessions.flatMap { $0.effectiveCapabilities.diagnosticLabels })
            .sorted().joined(separator: ", ")
        let sources = Set(sessions.map(\.observation.source)).sorted().joined(separator: ", ")
        let diagnostic = monitor.providerDiagnostics[kind]
        let duration = diagnostic.map { "\(Int($0.duration * 1000)) ms" } ?? L10n.string("Not scanned")
        let cache = diagnostic.map { L10n.format("%d cache hits", $0.cacheHits) } ?? L10n.string("Cache unknown")
        return
            L10n.format("%d observed sessions", sessions.count)
            + " · \(surfaces) · \(phases) · \(modes)/\(authorities) · \(sources) · \(capabilities) · \(duration) · \(cache)"
    }

    static func observedVersions(_ sessions: [AgentSession]) -> String {
        let versions = Set(sessions.compactMap { $0.observedVersion?.value }).sorted()
        return versions.isEmpty ? "unknown" : versions.joined(separator: " | ")
    }

    /// Partial reads retain their usable sessions, but must not claim that the
    /// whole source succeeded. A missing reason is not evidence of success.
    static func sourceHealthKey(for outcome: String) -> String {
        switch ProviderReadResult.Outcome(rawValue: outcome) {
        case .success: return "Data source ready"
        case .empty: return "Data source ready · no sessions"
        case .partial: return "Partial data · scan incomplete"
        case .incompatible: return "Data source version incompatible"
        case .failed, nil: return "Data temporarily unavailable"
        }
    }

    private func copyReport() {
        let lines =
            (IslandDebugTrace.enabled ? ["layoutTrace:"] + IslandDebugTrace.snapshot() : []) + [
                "LoopFwd \(AboutPane.appVersion)",
                "build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev")",
                "commit: \(Bundle.main.object(forInfoDictionaryKey: "LoopFwdBuildCommit") as? String ?? "uncommitted")",
                "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "architecture: \(Self.architecture)",
                "scanDurationMs: \(Int(monitor.lastScanDuration * 1000))",
                "sessionCount: \(monitor.agents.count)",
                "lastSuccessfulScan: \(monitor.lastSuccessfulScanAt?.description ?? "never")",
                "scanError: \(monitor.lastScanError ?? "none")",
                "lastNotificationDecision: \(operations.lastNotificationDecision ?? "none")",
                "lastReturnFailure: \(operations.lastReturnFailure ?? "none")",
                "lastControlFailure: \(operations.lastControlFailure ?? "none")",
            ]
            + monitor.surfaceDiagnostics.sorted { $0.key.rawValue < $1.key.rawValue }.map { surface, value in
                "\(surface.rawValue): attempted=\(value.lastAttemptAt) succeeded=\(value.lastSuccessfulAt?.description ?? "never") scanMs=\(Int(value.duration * 1000)) source=\(DiagnosticsSanitizer.sanitize(value.source)) outcome=\(value.outcome) reason=\(DiagnosticsSanitizer.sanitize(value.errorCategory ?? "none"))"
            }
            + SupportRegistry.shippedKinds.map { kind in
                let sessions = monitor.agents.filter { $0.kind == kind }
                let modes = Set(sessions.map(\.observation.mode.rawValue)).sorted().joined(separator: ",")
                let phases = Set(sessions.map { $0.status.label }).sorted().joined(separator: ",")
                let authorities = Set(sessions.map(\.observation.authority.rawValue)).sorted()
                    .joined(separator: ",")
                let surfaces = Set(sessions.map(\.surfaceID.rawValue)).sorted().joined(separator: ",")
                let capabilities = Set(sessions.flatMap { $0.effectiveCapabilities.diagnosticLabels })
                    .sorted().joined(separator: ",")
                let versions = Set(sessions.map { $0.integrationProfile.supportedVersions })
                    .sorted().joined(separator: " | ")
                let reasons = Set(sessions.compactMap(\.observation.reason))
                    .map { DiagnosticsSanitizer.sanitize($0) }.sorted().joined(separator: " | ")
                let diagnostic = monitor.providerDiagnostics[kind]
                return
                    "\(kind.rawValue): count=\(sessions.count) surfaces=\(surfaces.isEmpty ? "none" : surfaces) phases=\(phases.isEmpty ? "none" : phases) modes=\(modes.isEmpty ? "none" : modes) authority=\(authorities.isEmpty ? "none" : authorities) capabilities=\(capabilities.isEmpty ? "none" : capabilities) supportedVersions=\(versions.isEmpty ? "none" : versions) observedVersions=\(Self.observedVersions(sessions)) versionSources=\(Set(sessions.compactMap { $0.observedVersion?.source }).sorted().joined(separator: ",")) cli=\(kind.installedCLIPath != nil) scanMs=\(Int((diagnostic?.duration ?? 0) * 1000)) cacheHits=\(diagnostic?.cacheHits ?? 0) source=\(DiagnosticsSanitizer.sanitize(diagnostic?.source ?? "none")) outcome=\(diagnostic?.outcome ?? "unknown") error=\(diagnostic?.errorCategory ?? "none") reason=\(reasons)"
            }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "unknown"
        #endif
    }
}
