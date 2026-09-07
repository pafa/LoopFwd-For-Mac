import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - About

struct AboutPane: View {
    private var inApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// The real bundle version, so the About pane never lies about the build.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "LoopFwdReleaseVersion") as? String ?? "dev"
    }

    static func commitLabel(_ identity: String) -> String {
        let label = String(identity.prefix(16))
        return identity.hasSuffix("-dirty") ? label + " · " + L10n.string("Local changes") : label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection {
                VStack(spacing: 10) {
                    LoopFwdMarkView(variant: .color, placement: .about)
                    Text(L10n.string("LoopFwd"))
                        .font(.system(size: 18, weight: .bold))
                    Text(L10n.string("Monitor your local AI coding tasks at a glance."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(L10n.format("Version %@", Self.appVersion))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(
                        L10n.format(
                            "Build %@ · %@",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
                            Self.commitLabel(
                                Bundle.main.object(forInfoDictionaryKey: "LoopFwdBuildCommit") as? String
                                    ?? "uncommitted"))
                    )
                    Text(SupportRegistry.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }

            SSection(
                title: "Installation",
                footer: inApplications
                    ? "Running from /Applications."
                    : "Quit LoopFwd and drag it into Applications. If blocked, review System Settings → Privacy & Security → Open Anyway."
            ) {
                SRow(
                    title: inApplications ? "Installed in /Applications" : "Manual installation required",
                    subtitle: Bundle.main.bundlePath
                ) {
                    if inApplications {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AgentStatus.working.color)
                    } else {
                        Button(L10n.string("Open Applications")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                        }
                    }
                }
            }

            SSection(
                title: "Tracked data",
                footer:
                    "LoopFwd reads provider-owned local session stores and the process table. It never reads API keys or uploads transcript data."
            ) {
                ForEach(Array(SupportRegistry.shippedKinds.enumerated()), id: \.element.rawValue) { index, kind in
                    if index > 0 { SDiv() }
                    SRow(title: kind.displayName, subtitle: kind.supportTier.label) { EmptyView() }
                }
                SDiv()
                SRow(
                    title: "Every provider",
                    subtitle: "Process discovery with a safe fallback when session data is unavailable"
                ) { EmptyView() }
            }
        }
    }
}
