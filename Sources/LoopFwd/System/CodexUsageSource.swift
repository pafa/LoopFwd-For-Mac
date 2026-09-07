import Foundation

/// Shares the scanner's account boundary. Never use LoopFwd's own CODEX_HOME
/// or choose an account just because one of its conversations is newer.
struct CodexUsageSource: Equatable {
    var root: String?
    var observedPaths: [String] = []

    static func resolve(
        selected: String?, desktopRoot: String?, desktopRunning: Bool,
        rolloutPaths: [String], defaultRoot: String, cliRoots: [String?] = []
    ) -> Self {
        let roots = Set(rolloutPaths.compactMap(rootForRollout))
        let root: String?
        if let selected, !selected.isEmpty {
            root = ProviderDataLocations.absolutePath(selected)
        } else if (desktopRunning && desktopRoot == nil) || cliRoots.contains(where: { $0 == nil }) {
            root = nil
        } else {
            let discovered = roots.union(desktopRoot.map { [$0] } ?? []).union(cliRoots.compactMap { $0 })
            root = discovered.count > 1 ? nil : discovered.first ?? defaultRoot
        }
        return Self(
            root: root,
            observedPaths: Array(
                Set(
                    rolloutPaths.filter {
                        root != nil && rootForRollout($0) == root
                    }.map { ($0 as NSString).standardizingPath })
            ).sorted())
    }

    static func rootForRollout(_ path: String) -> String? {
        guard let path = ProviderDataLocations.absolutePath(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { return nil }
        var parent = url.deletingLastPathComponent()
        // Official layout: sessions/YYYY/MM/DD/rollout-*.jsonl.
        for digits in [2, 2, 4] {
            let component = parent.lastPathComponent
            guard component.count == digits, component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            parent.deleteLastPathComponent()
        }
        guard parent.lastPathComponent == "sessions" else { return nil }
        return parent.deletingLastPathComponent().path
    }

    /// Active paths survive calendar boundaries. Fallback discovery considers
    /// three recent month folders across two years, with a bounded file budget.
    func rollouts() -> [URL] {
        guard let root else { return [] }
        let fm = FileManager.default
        func children(_ url: URL, digits: Int) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter {
                    $0.lastPathComponent.count == digits
                        && $0.lastPathComponent.allSatisfy { $0.isASCII && $0.isNumber }
                }
                .sorted { $0.path > $1.path }
        }
        let base = URL(fileURLWithPath: root).appendingPathComponent("sessions")
        let months = children(base, digits: 4).prefix(2)
            .flatMap { children($0, digits: 2) }.sorted { $0.path > $1.path }.prefix(3)
        var candidates = Set(
            observedPaths.filter { Self.rootForRollout($0) == root }
                .map { ($0 as NSString).standardizingPath })
        var remaining = 4096
        for month in months {
            for day in children(month, digits: 2) {
                guard remaining > 0 else { break }
                guard
                    let enumerator = fm.enumerator(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                else { continue }
                for case let url as URL in enumerator {
                    remaining -= 1
                    if Self.rootForRollout(url.path) == root {
                        candidates.insert((url.path as NSString).standardizingPath)
                    }
                    if remaining <= 0 { break }
                }
            }
        }
        return candidates.compactMap { path -> (URL, Date)? in
            let url = URL(fileURLWithPath: path)
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (url, date)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            .prefix(8).map { $0.0 }
    }
}
