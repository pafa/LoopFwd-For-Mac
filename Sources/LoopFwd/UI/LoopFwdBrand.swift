import AppKit
import SwiftUI

/// Loads resources without relying on SwiftPM's generated `Bundle.module`
/// accessor, which can retain an absolute path to the build machine.
enum LoopFwdResources {
    static let bundle: Bundle? = {
        let name = "LoopFwd_LoopFwd.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name),
                FileManager.default.fileExists(atPath: url.path),
                let bundle = Bundle(url: url)
            {
                return bundle
            }
        }
        return nil
    }()

    static func image(named name: String, extension fileExtension: String, subdirectory: String) -> NSImage? {
        guard
            let url = bundle?.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            )
        else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct LoopFwdMarkView: View {
    enum Variant: Equatable {
        case color
        case template
    }

    /// The same mark has different optical requirements in each surface. In
    /// particular, a MenuBarExtra label must have a small fixed intrinsic size
    /// or AppKit may reserve the SVG's full 195×174 point canvas.
    enum Placement: Equatable {
        case menuBar
        case collapsedIsland
        case islandHeader
        case about

        var size: CGSize {
            switch self {
            case .menuBar: return CGSize(width: 14, height: 13)
            case .collapsedIsland: return CGSize(width: 17, height: 15)
            case .islandHeader: return CGSize(width: 20, height: 18)
            case .about: return CGSize(width: 63, height: 56)
            }
        }
    }

    let variant: Variant
    let placement: Placement

    private static let colorImage = LoopFwdResources.image(
        named: "loopfwd-symbol-on-dark",
        extension: "svg",
        subdirectory: "brand"
    )

    private static let templateImage: NSImage? = {
        guard
            let source = LoopFwdResources.image(
                named: "loopfwd-symbol-mono-black",
                extension: "svg",
                subdirectory: "brand"
            ), let image = source.copy() as? NSImage
        else { return nil }
        image.isTemplate = true
        image.size = Placement.menuBar.size
        return image
    }()

    var body: some View {
        Group {
            if let image = variant == .template ? Self.templateImage : Self.colorImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sailboat.fill")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: placement.size.width, height: placement.size.height)
        .fixedSize(horizontal: true, vertical: true)
        .clipped()
        .accessibilityHidden(true)
    }
}
