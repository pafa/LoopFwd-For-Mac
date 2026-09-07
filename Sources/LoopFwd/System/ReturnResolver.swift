import AppKit
import Foundation

struct ReturnResolution {
    let capability: ReturnCapability
    var reason: String? {
        if case .unavailable(let reason) = capability { return reason }
        return nil
    }
}

enum ReturnResolver {
    static func resolve(_ session: AgentSession) -> ReturnResolution {
        let target = session.returnTarget
        let unavailable: (String) -> ReturnResolution = { .init(capability: .unavailable(reason: $0)) }
        switch target {
        case .unavailable(let reason): return unavailable(reason)
        case .application(let bundleID, _):
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
                return unavailable("The provider application is not installed")
            }
        case .applicationLink(let bundleID, _, let url):
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
                Bundle(url: app)?.bundleIdentifier == bundleID
            else {
                return unavailable("No matching application handles this task link")
            }
        case .terminal(let app, let tty, let processID):
            return .init(
                capability: terminalCapability(
                    app: app, tty: tty, processID: processID,
                    helperAvailable: TerminalBridge.hasReturnHelper(for: app),
                    ttyExists: { FileManager.default.fileExists(atPath: "/dev/\($0)") }))
        case .web(let url):
            guard DeepSeekHarnessSessions.safeLoopbackURL(url.absoluteString) != nil,
                session.processID != nil, session.processStartedAt != nil
            else {
                return unavailable("The Harness process and local Web address cannot be verified")
            }
        }
        return .init(capability: target.capability)
    }

    /// Checks only local prerequisites, without probing UI or asking for
    /// permissions. The executor still revalidates the live pane on click.
    static func terminalCapability(
        app: String, tty: String?, processID: Int32?, helperAvailable: Bool,
        ttyExists: (String) -> Bool
    ) -> ReturnCapability {
        guard app == "tmux" || ProcessNaming.isSupportedTerminalHost(app) else {
            return .unavailable(reason: "This terminal does not have a supported return path")
        }
        guard helperAvailable else {
            return .unavailable(reason: "The terminal return helper is not available")
        }
        if ["Terminal", "iTerm", "tmux", "WezTerm"].contains(app) {
            guard let tty, tty.hasPrefix("tty"),
                tty.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
            else { return .unavailable(reason: "An exact terminal session could not be identified") }
            guard ttyExists(tty) else { return .unavailable(reason: "The task terminal has closed") }
            return .exact(label: app)
        }
        if app == "kitty" {
            guard let processID, processID > 0 else {
                return .unavailable(reason: "An exact terminal session could not be identified")
            }
            return .exact(label: app)
        }
        return .providerOnly(label: app)
    }
}

struct ReturnExecutionResult {
    let opened: Bool
    let exact: Bool
    let reason: String?
    var failure: ReturnFailure? = nil

    static func failed(_ failure: ReturnFailure) -> Self {
        .init(opened: false, exact: false, reason: failure.message, failure: failure)
    }
}

enum ReturnFailure: Error, Equatable {
    case targetUnavailable(String)
    case targetExpired
    case permissionDenied
    case timedOut
    case applicationUnavailable
    case helperFailed

    var message: String {
        switch self {
        case .targetUnavailable(let reason): return reason
        case .targetExpired: return "The task target has closed or changed. Refresh tasks and try again."
        case .permissionDenied:
            return
                "Allow LoopFwd to control this terminal in System Settings → Privacy & Security → Automation, then try again."
        case .timedOut: return "The return helper timed out. Check that the target app is responding, then try again."
        case .applicationUnavailable:
            return "The target application could not be opened. Review its location in Agents settings."
        case .helperFailed: return "The return helper failed. Open the task manually and review Setup status."
        }
    }

    static func fromProcess(_ result: BoundedProcess.Result, appleScript: Bool = false) -> Self? {
        if result.timedOut { return .timedOut }
        guard !result.succeeded else { return nil }
        // Only classify known osascript error codes. Never show raw stderr:
        // it can contain local paths or script arguments.
        if appleScript && !result.exceededOutputLimit {
            if result.output.contains("(-1743)") { return .permissionDenied }
            if result.output.contains("(-1712)") { return .timedOut }
            if result.output.contains("(1001)") { return .targetExpired }
            if result.output.contains("(-600)") { return .applicationUnavailable }
        }
        return .helperFailed
    }
}
