import Foundation

/// Picks a workspace directory for `claude --resume` hints when stored `projectPath` may be wrong.
///
/// Claude Code stores sessions under `.claude/projects/<encoded>/` where `encoded` is the absolute
/// project path with every `/` replaced by `-`. That map is not injective; metadata that decodes an
/// encoded workspace name by naively turning `-` into `/` can spell a path that does not exist.
/// This resolver uses the **authoritative** `encoded` directory name (from the written JSONL path),
/// enumerates every absolute path that re-encodes to it, and picks one that exists on disk.
package enum ProjectPathResolver {
    /// Same encoding as ``ClaudeCodeMigrator/encodedProjectPath(for:)``.
    package static func encodedClaudeProjectPath(_ absolutePath: String) -> String {
        MigratorUtils.encodedClaudeProjectPath(absolutePath)
    }

    package static func cdPath(
        forStoredProjectPath stored: String?,
        writtenJSONLPath: String,
        fileSystem: any FileSystemProtocol
    ) -> String? {
        let encoded = URL(fileURLWithPath: writtenJSONLPath).deletingLastPathComponent().lastPathComponent
        guard !encoded.isEmpty else { return stored }

        // Fast path: metadata path exists and matches the same bucket as the written file.
        if let stored, !stored.isEmpty {
            let normalized = URL(fileURLWithPath: stored).standardizedFileURL.path
            var isDirectory = ObjCBool(false)
            if fileSystem.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue,
               encodedClaudeProjectPath(normalized) == encoded
            {
                return normalized
            }
        }

        let existing = existingDirectoryCandidates(encoded: encoded, fileSystem: fileSystem)
        if existing.isEmpty {
            return stored
        }
        if existing.count == 1, let only = existing.first {
            return only
        }

        // Multiple filesystem paths collide under the same encoding (hyphenated segment vs extra nested dirs).
        if let stored, !stored.isEmpty {
            let normalized = URL(fileURLWithPath: stored).standardizedFileURL.path
            if existing.contains(normalized) {
                return normalized
            }
        }
        return existing.min(by: compareCandidatePaths)
    }

    /// Paths `P` with `encodedClaudeProjectPath(P) == encoded` that exist as directories.
    package static func existingDirectoryCandidates(
        encoded: String,
        fileSystem: any FileSystemProtocol
    ) -> [String] {
        var state = DFSState()
        let componentLists = enumeratePathComponentLists(encoded: encoded, state: &state)
        var results: [String] = []
        for components in componentLists {
            let path = "/" + components.joined(separator: "/")
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard encodedClaudeProjectPath(normalized) == encoded else { continue }
            var isDirectory = ObjCBool(false)
            if fileSystem.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue {
                results.append(normalized)
            }
        }
        return Array(Set(results)).sorted(by: compareCandidatePaths)
    }

    private struct DFSState {
        var callCount = 0
        var maxCalls = 500_000
    }

    /// Enumerates every `[String]` such that `"/".joined` re-encodes to `encoded`
    /// (must match ``encodedClaudeProjectPath``).
    package static func allPathComponentLists(encoded: String) -> [[String]] {
        var state = DFSState()
        return enumeratePathComponentLists(encoded: encoded, state: &state)
    }

    private static func enumeratePathComponentLists(encoded: String, state: inout DFSState) -> [[String]] {
        guard encoded.hasPrefix("-") else { return [] }
        let body = String(encoded.dropFirst())
        guard !body.isEmpty else { return [] }
        return dfs(remaining: body, components: [], encoded: encoded, state: &state)
    }

    private static func dfs(
        remaining: String,
        components: [String],
        encoded: String,
        state: inout DFSState
    ) -> [[String]] {
        state.callCount += 1
        if state.callCount > state.maxCalls {
            return []
        }

        let currentPath = "/" + components.joined(separator: "/")
        let enc = encodedClaudeProjectPath(currentPath)
        guard encoded.hasPrefix(enc) else { return [] }

        if remaining.isEmpty {
            return enc == encoded ? [components] : []
        }

        if !remaining.contains("-") {
            return dfs(remaining: "", components: components + [remaining], encoded: encoded, state: &state)
        }

        var results: [[String]] = []
        // Hyphens in this chunk are literal (one directory name that contains `-` characters).
        for tail in dfs(remaining: "", components: components + [remaining], encoded: encoded, state: &state) {
            results.append(tail)
        }
        // Hyphens separate additional path components.
        var index = remaining.startIndex
        while index < remaining.endIndex {
            if remaining[index] == "-" {
                let prefix = String(remaining[..<index])
                let suffix = String(remaining[remaining.index(after: index)...])
                if !prefix.isEmpty {
                    for tail in dfs(
                        remaining: suffix,
                        components: components + [prefix],
                        encoded: encoded,
                        state: &state
                    ) {
                        results.append(tail)
                    }
                }
            }
            index = remaining.index(after: index)
        }
        return results
    }

    /// Prefer shallower paths, then lexicographic (stable, deterministic).
    private static func compareCandidatePaths(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = URL(fileURLWithPath: lhs).pathComponents.count { $0 != "/" }
        let rhsDepth = URL(fileURLWithPath: rhs).pathComponents.count { $0 != "/" }
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        return lhs < rhs
    }
}
