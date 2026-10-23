import Foundation
import LiteCodeCore

enum Git {
    struct Output {
        var status: Int32
        var data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
        var ok: Bool { status == 0 }
    }

    /// Runs git; `includeErrors` folds stderr into `data` so failures can be shown to the user,
    /// and `input` is fed to stdin.
    static func run(_ args: [String], in directory: URL, includeErrors: Bool = false, input: Data? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // Background status polling must not take index.lock away from the user's own git commands.
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = includeErrors ? pipe : FileHandle.nullDevice
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, data: Data()))
                    return
                }
                if let stdin, let input {
                    // Written from another thread so a chatty git can't deadlock against us.
                    DispatchQueue.global(qos: .userInitiated).async {
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }
                // Drain before waiting: a full pipe would otherwise block git forever.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, data: data))
            }
        }
    }

    static func repositoryRoot(for directory: URL) async -> URL? {
        let output = await run(["rev-parse", "--show-toplevel"], in: directory)
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.ok, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).canonical
    }

    static func branch(in root: URL) async -> String? {
        let output = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.ok && !name.isEmpty ? name : nil
    }

    static func headCommit(in root: URL) async -> String? {
        let output = await run(["rev-parse", "HEAD"], in: root)
        let hash = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.ok && !hash.isEmpty ? hash : nil
    }

    static func status(in root: URL) async -> [GitChange]? {
        let output = await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        return output.ok ? GitStatusParser.parse(output.text) : nil
    }

    /// Files under `directory` that git tracks or would track (untracked but not ignored),
    /// relative to `directory`.
    static func listFiles(in directory: URL) async -> [String]? {
        let output = await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: directory)
        return output.ok ? output.text.split(separator: "\0").map(String.init) : nil
    }

    /// The HEAD version of a repository-relative path, or nil when HEAD has no such file.
    static func headContents(of path: String, in root: URL) async -> Data? {
        let output = await run(["show", "HEAD:\(path)"], in: root)
        return output.ok ? output.data : nil
    }

    /// The staged (index) version of a repository-relative path, or nil when it isn't in the index.
    static func indexContents(of path: String, in root: URL) async -> Data? {
        let output = await run(["show", ":\(path)"], in: root)
        return output.ok ? output.data : nil
    }

    // MARK: Staging

    /// `git add`; `-A` also stages deletions.
    static func stage(_ paths: [String], in root: URL) async -> Output {
        await run(["add", "-A", "--"] + paths, in: root, includeErrors: true)
    }

    /// Moves staged changes back to the working tree. Before the first commit there is no HEAD
    /// to restore from, so the paths are dropped from the index instead.
    static func unstage(_ paths: [String], in root: URL) async -> Output {
        if await headCommit(in: root) == nil {
            return await run(["rm", "--cached", "-r", "-q", "--"] + paths, in: root, includeErrors: true)
        }
        return await run(["restore", "--staged", "--"] + paths, in: root, includeErrors: true)
    }

    /// Reverts tracked paths in the working tree to their staged version.
    static func discard(_ paths: [String], in root: URL) async -> Output {
        await run(["restore", "--"] + paths, in: root, includeErrors: true)
    }

    /// Replaces the staged content of `path` without touching the working tree: how a single
    /// hunk is staged or unstaged. Keeps the index entry's mode (executable bit); new entries
    /// get 100644.
    static func setIndexContents(_ data: Data, of path: String, in root: URL) async -> Output {
        let blob = await run(["hash-object", "-w", "--stdin", "--path", path], in: root, includeErrors: true, input: data)
        guard blob.ok else { return blob }
        let hash = blob.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = await run(["ls-files", "-s", "--", path], in: root)
        let mode = entry.text.split(separator: " ").first.map(String.init) ?? "100644"
        return await run(["update-index", "--add", "--cacheinfo", "\(mode),\(hash),\(path)"], in: root, includeErrors: true)
    }
}
