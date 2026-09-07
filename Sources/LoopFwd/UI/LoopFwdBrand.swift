import AppKit
import SwiftUI

/// Loads resources without relying on SwiftPM's generated `Bundle.module`
/// accessor, which can retain an absolute path to the build machine.
enum LoopFwdResources {
    private final class ResourceAnchor: NSObject {}

    static let bundle: Bundle? = {
        var candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ]
        // XCTest keeps the resource bundle beside its test bundle. Packaged
        // apps must never search outside their own application directory.
        if Bundle.main.bundleURL.pathExtension != "app" {
            candidates.append(Bundle(for: ResourceAnchor.self).bundleURL.deletingLastPathComponent())
        }
        return findBundle(in: candidates.compactMap { $0 })
    }()

    static func findBundle(in candidates: [URL]) -> Bundle? {
        for candidate in candidates {
            let url = candidate.appendingPathComponent("LoopFwd_LoopFwd.bundle")
            if FileManager.default.fileExists(atPath: url.path),
                let bundle = Bundle(url: url)
            {
                return bundle
            }
        }
        return nil
    }

    /// Runs before SwiftUI, monitors or provider services are initialized.
    /// A release package must be self-contained even on a different machine.
    static func verifyPackagedResources() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",
            let resources = Bundle.main.resourceURL, let bundle,
            bundle.bundleURL.standardizedFileURL.path
                == resources.appendingPathComponent("LoopFwd_LoopFwd.bundle").standardizedFileURL.path,
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: "zh-Hans.lproj") != nil,
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj") != nil,
            L10n.string("Unknown", language: "zh-Hans") == "未知",
            L10n.string("Unknown", language: "en") == "Unknown",
            bundle.url(forResource: "loopfwd-symbol-on-dark", withExtension: "svg", subdirectory: "brand") != nil
        else { return false }
        return SupportRegistry.shippedKinds.allSatisfy { kind in
            guard let name = kind.iconFile else { return false }
            return bundle.url(forResource: name, withExtension: "png", subdirectory: "agents") != nil
        }
    }

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
