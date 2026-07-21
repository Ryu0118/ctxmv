#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// Helpers for kimi-code's workspace directory naming.
enum KimiCodeWorkspace {
    private enum Constants {
        static let workspacePrefix = "wd_"
        static let hashPrefixLength = 12
        static let maxSlugLength = 40
        static let fallbackSlug = "workspace"
    }

    /// kimi-code names each workspace `wd_<slug>_<sha256(normalized-root)[:12]>`, where `slug` is
    /// `slugifyWorkDirName(basename)` — NOT the raw basename. A raw basename diverges from kimi's own
    /// bucket for any root with uppercase letters, spaces, or non-ASCII characters (mirrors
    /// `encodeWorkDirKey`/`slugifyWorkDirName` in kimi-code's `workdir-slug.ts`).
    static func workspaceId(forRoot root: String) -> String {
        let normalized = normalizedPath(root)
        let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let slug = slugify(basename)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = MigratorUtils.hexString(Data(digest))
        return "\(Constants.workspacePrefix)\(slug)_\(hex.prefix(Constants.hashPrefixLength))"
    }

    /// Backslash-to-slash + trailing-slash strip, matching kimi-code's `encodeWorkDirKey` normalization
    /// (its hash input, not just its slug derivation).
    private static func normalizedPath(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Lowercase, collapse any run of non-`[a-z0-9._-]` to a single `-`, trim leading/trailing `-`,
    /// cap at 40 chars, and fall back to `"workspace"` for an empty/`.`/`..` result.
    private static func slugify(_ name: String) -> String {
        var slug = ""
        var lastWasSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.slugAllowed.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        slug = String(slug.drop { $0 == "-" })
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        slug = String(slug.prefix(Constants.maxSlugLength))
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty || slug == "." || slug == ".." ? Constants.fallbackSlug : slug
    }
}

private extension CharacterSet {
    static let slugAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
}

extension KimiCodeWorkspace {
    /// Shared by `indexLine` (encode) and the migrator's dedup scan (decode) so the two can't drift.
    struct IndexEntry: Codable {
        let sessionId: String
        let sessionDir: String
        let workDir: String
    }

    static func indexLine(sessionId: String, sessionDir: String, workDir: String) -> String? {
        MigratorUtils.encodeLine(IndexEntry(sessionId: sessionId, sessionDir: sessionDir, workDir: workDir))
    }

    /// Upserts the `wd_…` entry into `workspaces.json`, preserving `version`/existing workspaces/
    /// `deleted_workspace_ids`. Throws `MigrationError.writeFailed` on unparseable input (fail closed).
    static func upsertWorkspaces(
        existing: Data?,
        workspaceId: String,
        root: String,
        name: String,
        timestamp: String
    ) throws -> Data {
        var object: [String: Any]
        if let existing {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw MigrationError.writeFailed("workspaces.json is not valid JSON; refusing to overwrite")
            }
            object = parsed
        } else {
            object = ["version": 1, "workspaces": [String: Any](), "deleted_workspace_ids": [String]()]
        }

        var workspaces = object["workspaces"] as? [String: Any] ?? [:]
        if var entry = workspaces[workspaceId] as? [String: Any] {
            entry["last_opened_at"] = timestamp
            workspaces[workspaceId] = entry
        } else {
            workspaces[workspaceId] = [
                "root": root,
                "name": name,
                "created_at": timestamp,
                "last_opened_at": timestamp,
            ]
        }
        object["workspaces"] = workspaces

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
