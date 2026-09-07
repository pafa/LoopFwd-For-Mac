import Foundation

/// Estimates Claude usage-limit consumption from local transcripts, the way
/// ccusage-style tools do: every assistant entry carries `message.usage`;
/// we aggregate weighted tokens into hourly buckets, derive the active 5h
/// session block (Claude's rate-limit window: starts at the hour of the
/// first message after a ≥5h gap) and a rolling 7-day total, and compare
/// against per-plan budget estimates. All numbers are estimates — Anthropic
/// doesn't publish exact budgets.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct Snapshot: Equatable {
        var blockTokens: Double = 0
        var blockResetAt: Date?
        var weekTokens: Double = 0
        var hasIncompleteData = false

        func blockPercent(budget: Double) -> Int? {
            blockResetAt == nil || !budget.isFinite || budget <= 0
                ? nil : UsageTracker.displayPercent(blockTokens / budget * 100)
        }
        func weekPercent(budget: Double) -> Int? {
            !budget.isFinite || budget <= 0 ? nil : UsageTracker.displayPercent(weekTokens / budget * 100)
        }
    }

    /// Apply the existing 999% display ceiling before converting to Int.
    /// NaN, infinity and negative input are unknown, never an invented zero.
    static func displayPercent(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        return Int(min(value, 999).rounded())
    }

    /// (5h weighted-token budget, 7d budget) — rough community estimates.
    static func budgets(plan: String) -> (block: Double, week: Double) {
        switch plan {
        case "pro": return (8_000_000, 300_000_000)
        case "max20x": return (160_000_000, 6_000_000_000)
        default: return (40_000_000, 1_500_000_000)  // max5x
        }
    }

    /// Codex reports its real server-side rate limits in each rollout's
    /// `token_count` events — no estimation needed, we surface them verbatim.
    struct CodexWindow: Equatable {
        var usedPercent: Double
        var resetsAt: Date?
        var windowMinutes: Int
        var remainingPercent: Int? {
            guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
            return Int(max(0, 100 - usedPercent).rounded())
        }
        /// "5h" / "7d" style label derived from the window length.
        var label: String {
            if windowMinutes % 1440 == 0 { return "\(windowMinutes / 1440)d" }
            if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)h" }
            return "\(windowMinutes)m"
        }
    }

    struct CodexSnapshot: Equatable {
        var primary: CodexWindow?
        var secondary: CodexWindow?
        var planType: String?
        var reportedAt: Date?
        var hasData: Bool { primary != nil || secondary != nil }
        var isRecent: Bool { isRecent(at: Date()) }
        func isRecent(at now: Date) -> Bool {
            guard let reportedAt else { return false }
            let age = now.timeIntervalSince(reportedAt)
            return age >= 0 && age < 15 * 60
        }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var codex = CodexSnapshot()

    /// Per-file incremental state: transcripts are append-only, so after the
    /// first full parse we only read new bytes.
    struct FileState {
        var offset: UInt64
        var buckets: [Int: Double]  // unix-hour → weighted tokens
        var skippingOversizedLine = false
        var omittedRecords = 0
        var hasUnreadData = false
    }

    private var files: [String: FileState] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.loopfwd.usage", qos: .utility)
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    func start() {
        queue.async { self.recompute() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.queue.async { self?.recompute() }
        }
    }

    private func recompute() {
        guard UserDefaults.standard.bool(forKey: Pref.usageEnabled) else { return }
        recomputeCodex()
        guard UserDefaults.standard.bool(forKey: Pref.communityUsageEnabled) else {
            files.removeAll()
            DispatchQueue.main.async { self.snapshot = Snapshot() }
            return
        }
        let fm = FileManager.default
        let root = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? Self.home + "/.claude") + "/projects"
        let horizon = Date().addingTimeInterval(-8 * 24 * 3600)

        var seen = Set<String>()
        var sourceReadFailed = false
        if let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                sourceReadFailed = true; return true
            })
        {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mtime = values?.contentModificationDate, let fileSize = values?.fileSize else {
                    sourceReadFailed = true
                    seen.insert(url.path)
                    continue
                }
                guard mtime > horizon else { continue }
                let size = UInt64(max(0, fileSize))
                let path = url.path
                seen.insert(path)

                var state = files[path] ?? FileState(offset: 0, buckets: [:])
                if size > state.offset {
                    Self.ingest(path: path, state: &state)
                    files[path] = state
                } else if size < state.offset {
                    // Truncated/rewritten — reparse from scratch.
                    state = FileState(offset: 0, buckets: [:])
                    Self.ingest(path: path, state: &state)
                    files[path] = state
                }
            }
        } else {
            sourceReadFailed = true
        }
        files = files.filter { seen.contains($0.key) }

        publish(sourceReadFailed: sourceReadFailed)
    }

    // MARK: - Codex (exact server rate limits from ~/.codex rollouts)

    private func recomputeCodex() {
        // A Spark-only rollout must not hide a recently reported main bucket
        // from another active session. Keep body reads bounded to 8 × 128 KB.
        let candidates = latestCodexRollouts().compactMap { Self.codexSnapshot(path: $0.path) }
        guard
            let next = candidates.filter(\.hasData).max(by: {
                ($0.reportedAt ?? .distantPast) < ($1.reportedAt ?? .distantPast)
            })
        else { return }
        DispatchQueue.main.async {
            if self.codex != next { self.codex = next }
        }
    }

    static func codexSnapshot(path: String) -> CodexSnapshot? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Rate-limit events are small and near the end; the last 128KB is plenty.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.read(upToCount: 131_072) else { return nil }
        // Lossy on purpose — the window can begin mid-character. A strict
        // decode failed the whole read, blanking the Codex usage meter. See
        // TailRead. The garbled first line simply fails to parse as JSON, as
        // a partial line always did.
        let text = TailRead.decode(data)

        var rate: [String: Any]?
        var reportedAt: Date?
        for line in text.split(separator: "\n") where line.contains("\"rate_limits\"") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                obj["type"] as? String == "event_msg",
                let payload = obj["payload"] as? [String: Any],
                payload["type"] as? String == "token_count",
                let rl = payload["rate_limits"] as? [String: Any]
            else { continue }
            // Different metered buckets can be interleaved in one rollout.
            // Spark (codex_bengalfox) is not the main Codex allowance, even
            // when its event is newer or has the familiar 5h/7d windows.
            if let identity = rl["limit_id"], !(identity is NSNull) {
                guard identity as? String == "codex" else { continue }
            }
            rate = rl  // keep the last (freshest) one
            reportedAt = (obj["timestamp"] as? String).flatMap {
                Self.isoFractional.date(from: $0) ?? Self.iso.date(from: $0)
            }
        }
        guard let rate else { return nil }

        func window(_ key: String) -> CodexWindow? {
            guard let w = rate[key] as? [String: Any],
                let percentNumber = w["used_percent"] as? NSNumber,
                CFGetTypeID(percentNumber) != CFBooleanGetTypeID(),
                let minutesNumber = w["window_minutes"] as? NSNumber,
                CFGetTypeID(minutesNumber) != CFBooleanGetTypeID(),
                let mins = Int(exactly: minutesNumber.doubleValue), mins > 0,
                Self.displayPercent(percentNumber.doubleValue) != nil
            else { return nil }
            let reset = (w["resets_at"] as? NSNumber).flatMap { number -> Date? in
                let value = number.doubleValue
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), value.isFinite,
                    value >= Date.distantPast.timeIntervalSince1970,
                    value <= Date.distantFuture.timeIntervalSince1970
                else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            return CodexWindow(usedPercent: percentNumber.doubleValue, resetsAt: reset, windowMinutes: mins)
        }

        return CodexSnapshot(
            primary: window("primary"),
            secondary: window("secondary"),
            planType: (rate["plan_type"] as? String).map { String($0.prefix(80)) },
            reportedAt: reportedAt
        )
    }

    /// Up to eight recently modified rollouts under ~/.codex/sessions. We scan the
    /// latest month's day folders (not just today's) by mtime, so an empty
    /// current-day folder or a session that spans midnight still resolves.
    private func latestCodexRollouts() -> [URL] {
        let fm = FileManager.default
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        let base = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? Self.home + "/.codex") + "/sessions"
        guard let year = children(base).last.map({ base + "/" + $0 }),
            let month = children(year).last.map({ year + "/" + $0 })
        else { return [] }

        var newest: [(path: String, mtime: Date)] = []
        for day in children(month) {
            let dayDir = month + "/" + day
            for file in children(dayDir) where file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") {
                let path = dayDir + "/" + file
                guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                newest.append((path, m))
                newest.sort { $0.mtime == $1.mtime ? $0.path < $1.path : $0.mtime > $1.mtime }
                if newest.count > 8 { newest.removeLast() }
            }
        }
        return newest.map { URL(fileURLWithPath: $0.path) }
    }

    /// Parse appended bytes into hourly weighted-token buckets.
    static func ingest(path: String, state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            state.hasUnreadData = true
            return
        }
        defer { try? handle.close() }
        // Commit offsets and counts together. A read/seek failure must not
        // retain counts that would be counted again when the same bytes retry.
        var next = state
        var skippingOversizedLine = state.skippingOversizedLine
        do {
            try handle.seek(toOffset: state.offset)
            let consumption = try TailRead.consumeLines(
                handle: handle, skippingOversizedLine: &skippingOversizedLine
            ) { line in
                // Cheap pre-filter before JSON parsing 100MB+ of history.
                guard line.contains("\"usage\"") else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                    obj["type"] as? String == "assistant",
                    let message = obj["message"] as? [String: Any],
                    let usage = message["usage"] as? [String: Any],
                    let stamp = obj["timestamp"] as? String,
                    let date = Self.isoFractional.date(from: stamp) ?? Self.iso.date(from: stamp)
                else { return }

                let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                var values: [String: Double] = [:]
                for key in keys {
                    guard let raw = usage[key] else { continue }
                    guard let number = raw as? NSNumber,
                        CFGetTypeID(number) != CFBooleanGetTypeID(),
                        number.doubleValue.isFinite, number.doubleValue >= 0
                    else {
                        next.omittedRecords += 1
                        return
                    }
                    values[key] = number.doubleValue
                }
                // Cache reads are drastically cheaper — weight them down so the
                // estimate tracks cost/limits rather than raw bytes.
                let weighted =
                    values["input_tokens", default: 0]
                    + values["output_tokens", default: 0]
                    + values["cache_creation_input_tokens", default: 0]
                    + values["cache_read_input_tokens", default: 0] * 0.1
                guard weighted.isFinite else { next.omittedRecords += 1; return }
                guard weighted > 0 else { return }
                let hour = Int(date.timeIntervalSince1970 / 3600)
                let total = next.buckets[hour, default: 0] + weighted
                guard total.isFinite else { next.omittedRecords += 1; return }
                next.buckets[hour] = total
            }
            next.offset += consumption.bytes
            next.skippingOversizedLine = skippingOversizedLine
            next.omittedRecords += consumption.omittedRecords
            next.hasUnreadData = next.offset < (try handle.seekToEnd())
            state = next
        } catch {
            state.hasUnreadData = true
        }
    }

    private func publish(sourceReadFailed: Bool) {
        let nowHour = Int(Date().timeIntervalSince1970 / 3600)
        let weekStart = nowHour - 7 * 24

        var merged: [Int: Double] = [:]
        for state in files.values {
            for (hour, tokens) in state.buckets where hour >= weekStart - 5 {
                merged[hour, default: 0] += tokens
            }
        }

        // Session blocks: a block starts at the first active hour ≥5h after
        // the previous block's start; the current block is live if now is
        // inside blockStart+5h.
        var blockStart: Int?
        for hour in merged.keys.sorted() where merged[hour, default: 0] > 0 {
            if let start = blockStart {
                if hour >= start + 5 { blockStart = hour }
            } else {
                blockStart = hour
            }
        }

        var next = Snapshot()
        next.hasIncompleteData =
            sourceReadFailed
            || files.values.contains {
                $0.hasUnreadData || $0.omittedRecords > 0 || $0.skippingOversizedLine
            }
        next.weekTokens = merged.filter { $0.key >= weekStart }.values.reduce(0, +)
        if let start = blockStart, nowHour < start + 5 {
            next.blockTokens = (start..<(start + 5)).reduce(0) { $0 + (merged[$1] ?? 0) }
            next.blockResetAt = Date(timeIntervalSince1970: Double(start + 5) * 3600)
        }
        next.hasIncompleteData = next.hasIncompleteData || !next.weekTokens.isFinite || !next.blockTokens.isFinite

        DispatchQueue.main.async {
            if self.snapshot != next { self.snapshot = next }
        }
    }
}
