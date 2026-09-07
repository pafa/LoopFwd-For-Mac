import AppKit
import SwiftUI

enum NotchWing: Equatable {
    case left
    case right
}

enum NotchPointerZone: Equatable {
    case outside
    case center
    case leftWing
    case rightWing
}

enum NotchPointerPolicy {
    /// A collapsed panel only claims the physical notch target. Both wings and
    /// the large transparent NSPanel remainder must stay native-menu clickable.
    static func capturesMouseEvents(
        zone: NotchPointerZone,
        expanded: Bool,
        hidden: Bool
    ) -> Bool {
        guard !hidden else { return false }
        if expanded { return true }
        return zone == .center
    }

    static func wing(for zone: NotchPointerZone) -> NotchWing? {
        switch zone {
        case .leftWing: return .left
        case .rightWing: return .right
        case .outside, .center: return nil
        }
    }
}

/// Shared visual state only. Pointer authority remains in NotchPanel so a
/// click-through collapsed window never depends on SwiftUI receiving hover.
final class NotchPointerState: ObservableObject {
    static let shared = NotchPointerState()

    @Published private(set) var revealedWing: NotchWing?

    func reveal(_ wing: NotchWing?) {
        guard revealedWing != wing else { return }
        revealedWing = wing
    }
}

/// One geometry source for both the rendered collapsed surface and AppKit's
/// pointer zones. Keeping these values identical prevents an invisible strip
/// from claiming clicks beside the island.
enum NotchPointerGeometry {
    static func collapsedWidth(notch: NotchMetrics, pillStyle: String) -> CGFloat {
        guard notch.hasNotch else { return 240 }
        return notch.width + (pillStyle == "detailed" ? 440 : 180)
    }

    static func collapsedHeight(notch: NotchMetrics) -> CGFloat {
        notch.hasNotch ? notch.height + 1 : 10
    }

    static func surfaceRect(
        panelFrame: CGRect,
        notch: NotchMetrics,
        pillStyle: String
    ) -> CGRect {
        let width = collapsedWidth(notch: notch, pillStyle: pillStyle)
        let height = collapsedHeight(notch: notch)
        return CGRect(
            x: panelFrame.midX - width / 2,
            y: panelFrame.maxY - height,
            width: width,
            height: height
        )
    }

    static func zone(
        at point: CGPoint,
        panelFrame: CGRect,
        notch: NotchMetrics,
        pillStyle: String
    ) -> NotchPointerZone {
        let surface = surfaceRect(
            panelFrame: panelFrame,
            notch: notch,
            pillStyle: pillStyle
        )
        guard surface.contains(point) else { return .outside }
        guard notch.hasNotch else { return .center }

        let center = CGRect(
            x: panelFrame.midX - notch.width / 2,
            y: surface.minY,
            width: notch.width,
            height: surface.height
        )
        if center.contains(point) { return .center }
        return point.x < center.minX ? .leftWing : .rightWing
    }
}
