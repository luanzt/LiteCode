import Foundation

/// VS Code's list order for "/"-separated relative paths (`comparePaths`), used by search results
/// and source control: folder by folder, a folder's files before its subfolders, names in natural
/// order ("a2" < "a10").
public enum PathOrder {
    public static func precedes(_ path: String, _ other: String) -> Bool {
        let parts = path.split(separator: "/"), otherParts = other.split(separator: "/")
        for index in 0..<min(parts.count, otherParts.count) {
            let isFile = index == parts.count - 1, otherIsFile = index == otherParts.count - 1
            if isFile != otherIsFile { return isFile }
            let order = String(parts[index]).localizedStandardCompare(String(otherParts[index]))
            if order != .orderedSame { return order == .orderedAscending }
        }
        return parts.count < otherParts.count
    }
}
