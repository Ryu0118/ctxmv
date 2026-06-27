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
/// case is recoverable for free: the shell exposes the *logical* invocation directory via the
/// `PWD` environment variable, while `getcwd`/`FileManager.currentDirectoryPath` returns the
/// *physical* one (symlinks resolved). When `PWD` is a genuine alias of the physical project
/// path, both encodings are known strings and we can write to both buckets.
package enum ClaudeProjectAliasResolver {
    /// Returns logical path aliases of `physicalPath` that are safe to additionally write to.
    ///
    /// An alias is returned only when it resolves (symlinks resolved) to the same canonical path
    /// as `physicalPath` and differs from it as a string. This guard guarantees we never write a
    /// session into an unrelated project directory when ctxmv happens to be invoked from elsewhere.
    package static func aliasPaths(
        forPhysicalPath physicalPath: String,
        environment: [String: String]
    ) -> [String] {
        guard !physicalPath.isEmpty else { return [] }
        let canonicalPhysical = canonicalize(physicalPath)

        guard let pwd = environment["PWD"], !pwd.isEmpty else { return [] }
        guard pwd != physicalPath else { return [] }
        guard canonicalize(pwd) == canonicalPhysical else { return [] }
        return [pwd]
    }

    /// Resolves symlinks and standardizes the path for canonical comparison.
    private static func canonicalize(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
