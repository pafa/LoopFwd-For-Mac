import SwiftUI

/// The agent's real brand logo with a status dot badge in the corner.
/// Falls back to a tinted SF-symbol avatar for brands without a bundled icon.
struct AgentIconView: View {
    let kind: AgentKind
    let status: AgentStatus
    var size: CGFloat = 26
    /// Show the corner status dot. Off for static lists (e.g. Settings → Agents).
    var showStatus: Bool = true

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        icon
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if showStatus {
                    StatusDot(color: status.color, active: status == .working)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .background(Circle().fill(.black).padding(-2))
                        .offset(x: 2, y: 2)
                }
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = Self.load(kind: kind) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .opacity(status == .idle ? 0.5 : 1)
        } else {
            ZStack {
                Circle().fill(kind.color.gradient)
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .opacity(status == .idle ? 0.5 : 1)
        }
    }

    private static func load(kind: AgentKind) -> NSImage? {
        guard let file = kind.iconFile else { return nil }
        if let cached = cache[file] { return cached }
        guard let image = LoopFwdResources.image(named: file, extension: "png", subdirectory: "agents")
        else { return nil }
        cache[file] = image
        return image
    }
}
