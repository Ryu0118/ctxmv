# ctxmv

CLI tool to read, display, export, and migrate conversation sessions across AI coding agents (Claude Code, Codex, Cursor).

## Commands

- Build: `swift build`
- Test: `swift test`
- Run: `swift run ctxmv <subcommand>`

## Architecture

3-layer structure: CLI → Kit → Providers/Migrators.

- `Sources/ctxmv/` — Entry point (CTXMVMain.swift only)
- `Sources/CTXMVCLI/` — ArgumentParser-based CLI command definitions
- `Sources/CTXMVKit/` — Core logic (CLI-independent)
  - `Migrators/` — Session writers per agent (`SessionMigrator` protocol)

## Code Style

- Swift 6.0 strict concurrency (`Sendable` required)
- Default access level is `package` (`public` only for CLI entry)
- String identifiers must go through enum `rawValue`. No direct string comparison
- `DateFormatter` / `ISO8601DateFormatter` must be centralized in `DateUtils`. No local definitions
- Use `MigratorUtils.encodeLine` for JSON encode-to-line
- Use `MigratorUtils.hexString` for hex conversion
- Use `MigrationMeta.migrationType` instead of `"ctxmv_migration"` literal
- Add doc comments to non-trivial types and functions whose role is not obvious from the call site
- Add concise inline comments for non-obvious invariants, format quirks, or compatibility requirements; do not comment trivial code

## Session Storage Locations

- Claude Code: `~/.claude/projects/<encoded-path>/<session-id>.jsonl`
- Codex: `~/.codex/sessions/<year>/<month>/<day>/rollout-<date>-<uuid>.jsonl`
- Cursor (store.db): `~/.cursor/chats/<md5-hash>/<session-id>/store.db`
- Cursor (transcripts): `~/.cursor/projects/<encoded-workspace>/agent-transcripts/<session-id>.jsonl`

## Testing

- Tests live in `Tests/CTXMVKitTests/`
- I/O is mocked via `FileSystemProtocol` + `MockFileSystem`
- SQLite is mocked via `MockSQLiteProvider`
- Use real session data structures as reference when adding tests

## Gotchas

- Cursor `store.db` uses protobuf + SHA-256 blob DAG. `meta` table values are hex-encoded JSON
- Claude Code `--resume` requires the first line to be `progress` type, otherwise the session is not recognized
- Cursor `--resume` does not render past messages in TUI, but context is preserved
- Codex records assistant responses in both `event_msg(agent_message)` and `response_item`. Both must be written for resume to restore responses
- Dedup uses `originId + originSource + originDigest` (SHA-256 of conversation history). Re-migration is allowed when the source session has been updated
