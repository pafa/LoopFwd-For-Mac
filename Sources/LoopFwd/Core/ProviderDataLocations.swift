import Foundation

/// Configuration locations are explicit paths, not inferred from the newest
/// conversation. Finder's environment is never substituted for the observed app.
enum ProviderDataLocations {
    enum LocationError: LocalizedError {
        case unavailable
        case ambiguous
        case invalidPath

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Data directory unavailable. Choose it in Agents settings."
            case .ambiguous: return "Multiple data directories found. Choose one in Agents settings."
            case .invalidPath: return "Data directory must be an absolute path."
            }
        }
    }

    static func absolutePath(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("\0"), !value.contains("\n") else { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    static func codexDesktopRoot(
        selected: String?,
        processEnvironments: [[String: String]?],
        defaultRoot: String
    ) throws -> String {
        if let selected, !selected.isEmpty {
            guard let path = absolutePath(selected) else { throw LocationError.invalidPath }
            return path
        }
        guard !processEnvironments.isEmpty, processEnvironments.allSatisfy({ $0 != nil }) else {
            throw LocationError.unavailable
        }
        let roots = try Set(
            processEnvironments.map { environment in
                let raw = environment?["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultRoot
                guard let path = absolutePath(raw) else { throw LocationError.invalidPath }
                return path
            })
        guard roots.count == 1, let root = roots.first else { throw LocationError.ambiguous }
        return root
    }

    static var claudeConfigurationDirectory: String {
        absolutePath(UserDefaults.standard.string(forKey: Pref.claudeConfigurationDirectory))
            ?? NSHomeDirectory() + "/.claude"
    }
}
