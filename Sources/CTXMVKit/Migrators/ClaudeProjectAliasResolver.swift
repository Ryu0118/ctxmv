import Foundation

/// Finds symlink-aliased project directories so a migrated Claude Code session is resolvable
/// regardless of which path the user later runs `claude --resume` from.
///
/// Claude Code resolves `--resume` against the current working directory: it only looks in
/// `~/.claude/projects/<encoded cwd>/`. When the project lives under a symlinked parent
/// (e.g. `~/workspace -> /Volumes/Disk/workspace`), the physical path stored in session
/// metadata and the logical path the user `cd`s into encode to *different* buckets. Writing
/// only to the physical bucket makes resume fail from the logical cwd, and vice versa.
///
/// We cannot derive arbitrary symlink aliases without scanning the filesystem, but the common
/// case is recoverable for free: the shell exposes the *logical* working directory via `PWD`
/// (read at the CLI boundary), while `getcwd`/`FileManager.currentDirectoryPath` returns the
/// *physical* one (symlinks resolved). When the logical path is a genuine alias of the physical
/// project path, both encodings are known strings and we can write to both buckets.
package enum ClaudeProjectAliasResolver {
    /// Returns `logicalCwd` when it is a genuine symlink alias of `physicalPath`, otherwise `nil`.
    ///
    /// An alias is accepted only when it differs from `physicalPath` as a string yet resolves
    /// (symlinks resolved) to the same canonical path. That guard guarantees we never write a
    /// session into an unrelated project directory when ctxmv is invoked from elsewhere.
    package static func alias(
        forPhysicalPath physicalPath: String,
        logicalCwd: String?
    ) -> String? {
        // Cheap string checks first; symlink resolution touches the filesystem, so defer it.
        guard let logicalCwd, !logicalCwd.isEmpty, !physicalPath.isEmpty else { return nil }
        guard logicalCwd != physicalPath else { return nil }
        guard canonicalize(logicalCwd) == canonicalize(physicalPath) else { return nil }
        return logicalCwd
    }

    /// Resolves symlinks and standardizes the path for canonical comparison.
    private static func canonicalize(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
