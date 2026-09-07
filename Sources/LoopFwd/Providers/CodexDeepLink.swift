import Foundation

/// Builds the local-task route registered by Codex Desktop.
///
/// Keep this deliberately narrow: session identifiers come from Codex's own
/// registry or app-server, and an invalid identifier must not degrade to merely
/// activating whichever Codex window happens to be open.
enum CodexDeepLink {
    static func returnTarget(threadID: String) -> ReturnTarget {
        guard let url = threadURL(threadID: threadID) else {
            return .unavailable(reason: "The Codex task link could not be resolved")
        }
        return .applicationLink(
            bundleIdentifier: "com.openai.codex",
            name: "Codex",
            url: url
        )
    }

    static func threadURL(threadID: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !threadID.isEmpty,
            threadID.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        return components.url
    }
}
