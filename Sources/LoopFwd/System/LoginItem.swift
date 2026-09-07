import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Mutations are initiated only
/// by explicit controls in Settings and return their failure to the caller.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(enabled: Bool) -> Result<Void, Error> {
        guard isAvailable else { return .failure(LoginItemError.unavailable) }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            NSLog("LoginItem: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private enum LoginItemError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return L10n.string("Launch at Login is available only from a packaged LoopFwd app.")
            }
        }
    }
}
