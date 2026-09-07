import Foundation

/// Removes machine-specific paths and credential-shaped values before a
/// diagnostics report leaves the app. Provider error messages are not assumed
/// to be safe merely because LoopFwd did not generate them.
enum DiagnosticsSanitizer {
    static func sanitize(_ value: String, limit: Int = 160) -> String {
        var result = value.replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        result = result.replacingOccurrences(
            of: #"(?:file://)?/(?:Users|private|tmp|var|Volumes|Applications)(?:/[^\s|,;]+)+"#,
            with: "<path>",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{12,})"#,
            with: "<redacted-secret>",
            options: .regularExpression
        )
        result =
            result
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return result.count > limit ? String(result.prefix(limit)) : result
    }
}
