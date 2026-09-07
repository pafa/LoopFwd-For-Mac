import Foundation

enum ReaderDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

/// Gives a cooperative async Reader a bounded share of the global scan. The
/// losing task is cancelled, so URLSession-backed Readers stop without holding
/// the rest of the provider refresh behind them.
enum ReaderDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Value
    ) async -> ReaderDeadlineResult<Value> {
        guard seconds > 0 else { return .timedOut }
        let nanoseconds = UInt64(seconds * 1_000_000_000)

        return await withTaskGroup(of: ReaderDeadlineResult<Value>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    return .timedOut
                } catch {
                    return .timedOut
                }
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
