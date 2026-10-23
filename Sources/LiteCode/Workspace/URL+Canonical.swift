import Foundation

extension URL {
    /// The realpath(3) form. Unlike `resolvingSymlinksInPath()`, which strips `/private`, this
    /// matches the paths reported by git, FSEvents, and directory listings.
    var canonical: URL {
        guard isFileURL, let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}
