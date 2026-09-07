import Foundation

/// Recovers context after a restart without loading an entire rollout. The
/// cursor survives polls (including unchanged files); no transcript is saved.
final class CodexTaskHistory {
    struct Result {
        let prompt: String?
        let isRecovering: Bool
        let bytesRead: Int
    }

    private struct Cursor {
        let upperBound: UInt64
        let lowerBound: UInt64
        var offset: UInt64
        var reversedLine: [UInt8] = []
        // An append may leave the final JSON line unfinished. Never parse it.
        var discarding = true
    }

    private struct Entry {
        let fileID: UInt64
        var fileSize: UInt64
        var scannedThrough: UInt64 = 0
        var prompt: String?
        var cursor: Cursor?
        var accessedAt = Date()
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let maximumRecordBytes = 256 * 1024
    private let maximumEntries = 64

    func recover(
        path: String, tailPrompt: String?, budget: Int = 2 * 1024 * 1024,
        extract: (Data) -> String?
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return .init(prompt: entries[path]?.prompt, isRecovering: false, bytesRead: 0) }

        var entry = entries[path] ?? Entry(fileID: fileID, fileSize: size)
        if entry.fileID != fileID || size < entry.fileSize {
            entry = Entry(fileID: fileID, fileSize: size)
        }
        entry.fileSize = size
        entry.accessedAt = Date()

        if let tailPrompt {
            entry.prompt = String(tailPrompt.prefix(16 * 1024))
            entry.scannedThrough = size
            entry.cursor = nil
        } else if entry.cursor == nil, size > entry.scannedThrough {
            // Include one record's overlap: the previous EOF may have been in
            // the middle of a user message that has since finished writing.
            let lower =
                entry.scannedThrough > UInt64(maximumRecordBytes)
                ? entry.scannedThrough - UInt64(maximumRecordBytes) : 0
            entry.cursor = Cursor(upperBound: size, lowerBound: lower, offset: size)
        }

        var bytesRead = 0
        if var cursor = entry.cursor, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            var found: String?
            while cursor.offset > cursor.lowerBound, bytesRead < budget, found == nil {
                let count = min(256 * 1024, budget - bytesRead, Int(cursor.offset - cursor.lowerBound))
                let start = cursor.offset - UInt64(count)
                guard (try? handle.seek(toOffset: start)) != nil,
                    let chunk = try? handle.read(upToCount: count), chunk.count == count
                else { break }
                bytesRead += count
                for byte in chunk.reversed() {
                    if byte == 10 {
                        if !cursor.discarding, !cursor.reversedLine.isEmpty {
                            found = extract(Data(cursor.reversedLine.reversed()))
                        }
                        cursor.reversedLine.removeAll(keepingCapacity: true)
                        cursor.discarding = false
                        if found != nil { break }
                    } else if !cursor.discarding {
                        if cursor.reversedLine.count < maximumRecordBytes {
                            cursor.reversedLine.append(byte)
                        } else {
                            cursor.reversedLine.removeAll(keepingCapacity: true)
                            cursor.discarding = true
                        }
                    }
                }
                cursor.offset = start
            }
            if found == nil, cursor.offset == 0, !cursor.discarding {
                found = extract(Data(cursor.reversedLine.reversed()))
            }
            if let found { entry.prompt = String(found.prefix(16 * 1024)) }
            if found != nil || cursor.offset == cursor.lowerBound {
                entry.scannedThrough = cursor.upperBound
                entry.cursor = nil
            } else {
                entry.cursor = cursor
            }
        }

        entries[path] = entry
        if entries.count > maximumEntries,
            let oldest = entries.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key
        {
            entries.removeValue(forKey: oldest)
        }
        return .init(
            prompt: entry.prompt,
            isRecovering: entry.cursor != nil || size > entry.scannedThrough,
            bytesRead: bytesRead)
    }
}
