import Foundation

/// Decoding the trailing window of an agent transcript.
///
/// Transcripts grow to 100MB+, so every reader seeks to `size - N` and parses
/// only what follows. That offset is a *byte* count chosen without regard to
/// character boundaries, so the window regularly begins in the middle of a
/// multi-byte UTF-8 sequence — an emoji, a curly quote, an accented letter, a
/// box-drawing character in some tool output.
///
/// `String(data:encoding:.utf8)` is strict and returns nil for exactly that
/// input. Every caller treated nil as "no entries", so a single split character
/// blanked the whole card — title, prompt, activity, model, todos — and the
/// empty result was then cached under the file's mtime, keeping it blank until
/// the next write. Measured on a real transcript, roughly one read in 700 began
/// mid-character; transcripts containing emoji or non-English text fare worse.
///
/// Decoding lossily instead cannot fail. The replacement characters only ever
/// land in the window's first line, which every caller already discards as
/// partial, so nothing downstream sees them.
enum TailRead {

    /// Decode a byte window that may begin mid-character.
    static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Usable lines from a tail window.
    ///
    /// - Parameter dropsFirstLine: whether the window began mid-line, making
    ///   its first line a fragment of a record that started before the offset.
    static func lines(_ data: Data, dropsFirstLine: Bool) -> [Substring] {
        var lines = decode(data).split(separator: "\n", omittingEmptySubsequences: true)
        if dropsFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    struct Consumption {
        var bytes: UInt64
        var omittedRecords: Int
    }

    /// Bounded incremental reading, including records without a newline.
    /// Ordinary partial lines are retried from their beginning. An oversized
    /// record is discarded through its newline, across calls if necessary;
    /// its suffix must never be interpreted as a new record. Callers expose
    /// omissions and unread bytes instead of presenting partial totals as full.
    static func consumeLines(
        handle: FileHandle,
        skippingOversizedLine: inout Bool,
        chunkSize: Int = 64 * 1024,
        maximumBytes: Int = 4 * 1024 * 1024,
        maximumLineBytes: Int = 1024 * 1024,
        _ body: (Substring) -> Void
    ) throws -> Consumption {
        precondition(chunkSize > 0 && maximumLineBytes > 0 && maximumBytes > maximumLineBytes)
        var carry = Data()
        var totalRead = 0
        var omittedRecords = 0
        while totalRead < maximumBytes,
            let chunk = try handle.read(upToCount: min(chunkSize, maximumBytes - totalRead)), !chunk.isEmpty
        {
            totalRead += chunk.count
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n"))
                let end = newline ?? chunk.endIndex
                if !skippingOversizedLine {
                    if end - start > maximumLineBytes - carry.count {
                        carry.removeAll(keepingCapacity: false)
                        skippingOversizedLine = true
                        omittedRecords += 1
                    } else {
                        carry.append(contentsOf: chunk[start..<end])
                    }
                }
                if let newline {
                    if !skippingOversizedLine && !carry.isEmpty { body(Substring(decode(carry))) }
                    carry.removeAll(keepingCapacity: true)
                    skippingOversizedLine = false
                    start = newline + 1
                } else {
                    break
                }
            }
        }
        return Consumption(bytes: UInt64(totalRead - carry.count), omittedRecords: omittedRecords)
    }
}
