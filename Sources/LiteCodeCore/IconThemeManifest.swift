import Foundation

/// A VS Code file icon theme manifest (the Material Icon Theme's `material-icons.json`),
/// resolved the way VS Code's explorer does for the dark variant.
public struct IconThemeManifest: Sendable {
    private let iconPaths: [String: String]
    private let fileNames: [String: String]
    private let fileExtensions: [String: String]
    private let folderNames: [String: String]
    private let folderNamesExpanded: [String: String]
    private let defaultFile: String
    private let defaultFolder: String
    private let defaultFolderExpanded: String

    private struct Raw: Decodable {
        struct Definition: Decodable { var iconPath: String }
        var iconDefinitions: [String: Definition]
        var fileNames: [String: String]
        var fileExtensions: [String: String]
        var folderNames: [String: String]
        var folderNamesExpanded: [String: String]
        var file: String
        var folder: String
        var folderExpanded: String
    }

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        iconPaths = raw.iconDefinitions.mapValues(\.iconPath)
        fileNames = Self.lowercasedKeys(raw.fileNames)
        fileExtensions = Self.lowercasedKeys(raw.fileExtensions)
        // Keys containing "/" match folder path suffixes; only plain names are supported here.
        folderNames = Self.lowercasedKeys(raw.folderNames.filter { !$0.key.contains("/") })
        folderNamesExpanded = Self.lowercasedKeys(raw.folderNamesExpanded.filter { !$0.key.contains("/") })
        defaultFile = raw.file
        defaultFolder = raw.folder
        defaultFolderExpanded = raw.folderExpanded
    }

    /// VS Code matches names case-insensitively.
    private static func lowercasedKeys(_ map: [String: String]) -> [String: String] {
        Dictionary(map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Icon id for a file: exact file name first, then extensions from the longest
    /// compound suffix down (`a.test.tsx` tries `test.tsx`, then `tsx`).
    public func fileIcon(for name: String) -> String {
        let name = name.lowercased()
        if let icon = fileNames[name] { return icon }
        var remainder = Substring(name)
        while let dot = remainder.firstIndex(of: ".") {
            remainder = remainder[remainder.index(after: dot)...]
            if let icon = fileExtensions[String(remainder)] { return icon }
        }
        return defaultFile
    }

    public func folderIcon(for name: String, expanded: Bool) -> String {
        let name = name.lowercased()
        if expanded {
            return folderNamesExpanded[name] ?? defaultFolderExpanded
        }
        return folderNames[name] ?? defaultFolder
    }

    /// SVG file name for an icon id, e.g. `react_ts.svg`.
    public func svgFileName(for icon: String) -> String? {
        iconPaths[icon].map { ($0 as NSString).lastPathComponent }
    }
}
