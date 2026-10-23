import AppKit
import LiteCodeCore
import SwiftUI

/// File and folder icons from the bundled Material Icon Theme (Resources/MaterialIcons).
@MainActor
enum MaterialIcons {
    private static let directory: URL? = {
        // Inside LiteCode.app the SwiftPM resource bundle sits in Contents/Resources; for
        // `swift run` it sits next to the executable, where Bundle.module finds it.
        let bundle = Bundle.main.url(forResource: "LiteCode_LiteCode", withExtension: "bundle").flatMap(Bundle.init(url:))
            ?? Bundle.module
        return bundle.url(forResource: "MaterialIcons", withExtension: nil)
    }()

    private static let manifest: IconThemeManifest? = directory
        .flatMap { try? Data(contentsOf: $0.appendingPathComponent("material-icons.json")) }
        .flatMap { try? IconThemeManifest(data: $0) }

    private static var cache: [String: NSImage] = [:]

    static func file(named name: String) -> NSImage? {
        manifest.flatMap { image(for: $0.fileIcon(for: name)) }
    }

    static func folder(named name: String, expanded: Bool) -> NSImage? {
        manifest.flatMap { image(for: $0.folderIcon(for: name, expanded: expanded)) }
    }

    private static func image(for icon: String) -> NSImage? {
        if let cached = cache[icon] { return cached }
        guard let directory, let file = manifest?.svgFileName(for: icon),
              let image = NSImage(contentsOf: directory.appendingPathComponent("icons").appendingPathComponent(file))
        else { return nil }
        cache[icon] = image
        return image
    }
}

/// A 16-point Material icon for a file or folder, falling back to an SF Symbol.
struct FileIcon: View {
    let name: String
    var isDirectory = false
    var isExpanded = false

    var body: some View {
        let image = isDirectory
            ? MaterialIcons.folder(named: name, expanded: isExpanded)
            : MaterialIcons.file(named: name)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: isDirectory ? "folder" : "doc.text").resizable().scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
    }
}
