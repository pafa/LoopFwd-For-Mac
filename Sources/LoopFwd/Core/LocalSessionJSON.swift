import Foundation

/// Small, read-only helpers shared by provider session readers.
///
/// Agent transcripts can grow without bound and are often being appended while
/// LoopFwd scans them. Readers therefore parse a bounded head or tail, ignore a
/// partial JSON line, and never mutate provider-owned state.
enum LocalSessionJSON {
    typealias Object = [String: Any]

    static func headObjects(path: String, maxBytes: Int = 128 * 1024) -> [Object] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return [] }
        return objects(in: TailRead.lines(data, dropsFirstLine: false))
    }

    static func tailObjects(path: String, maxBytes: Int = 768 * 1024) -> [Object] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return [] }
        return objects(in: TailRead.lines(data, dropsFirstLine: offset > 0))
    }

    static func object(path: String) -> Object? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    static func text(_ value: Any?) -> String? {
        if let value = value as? String { return compact(value) }
        if let object = value as? Object {
            if let value = text(object["text"]) { return value }
            if let value = text(object["content"]) { return value }
        }
        if let array = value as? [Any] {
            let pieces = array.compactMap(text)
            return compact(pieces.joined(separator: "\n"))
        }
        return nil
    }

    static func compact(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func fileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    static func standardPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    static func argumentValue(_ args: String, names: Set<String>) -> String? {
        let tokens = args.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if names.contains(token), index + 1 < tokens.count,
                !tokens[index + 1].hasPrefix("-")
            {
                return tokens[index + 1]
            }
            for name in names where token.hasPrefix(name + "=") {
                return String(token.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    private static func objects(in lines: [Substring]) -> [Object] {
        lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Object
        }
    }
}
