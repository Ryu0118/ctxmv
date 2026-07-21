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
- Kimi Code: `~/.kimi-code/sessions/wd_<basename>_<sha256(root)[:12]>/session_<id>/agents/main/wire.jsonl` (+ `state.json`; global `session_index.jsonl` / `workspaces.json`)

## Testing

- Tests live in `Tests/CTXMVKitTests/`
- I/O is mocked via `FileSystemProtocol` + `MockFileSystem`
- SQLite is mocked via `MockSQLiteProvider`
- Use real session data structures as reference when adding tests

## Gotchas

- Cursor `store.db` uses protobuf + SHA-256 blob DAG. `meta` table values are hex-encoded JSON
- Claude Code `--resume` (TUI) rejects a session ("Failed to resume") whose **first line is `progress`**. Write the `ctxmv_migration` meta as a **trailing** `progress` line instead; dedup reads the whole file so position does not matter. The first line must be the first conversation entry. Each user/assistant entry must also carry `cwd`/`version`/`gitBranch`/`isSidechain` and a `parentUuid` chain, and assistant messages need a non-empty `message.model` — without these resume fails. (The headless `-p` resume path is lenient and does NOT surface these failures; verify against the TUI.)
- Cursor `--resume` does not render past messages in TUI, but context is preserved
- Codex records assistant responses in both `event_msg(agent_message)` and `response_item`. Both must be written for resume to restore responses
- Dedup uses `originId + originSource + originDigest` (SHA-256 of conversation history). Re-migration is allowed when the source session has been updated
- Kimi Code stores user turns as `turn.prompt` + `context.append_message` with `origin.kind=user`; assistant turns exist ONLY as `context.append_loop_event` (`content.part` type `text`), grouped per turn. `role=user` append_messages with other `origin.kind` (kimi-code's `PromptOrigin` union also has `skill_activation`/`plugin_command`/`shell_command`/`compaction_summary`/`system_trigger`/`task`/`cron_job`/`cron_missed`/`hook_result`/`retry`, not just `injection`) are NOT user turns. The TUI renders user prompts from `context.append_message` (not `turn.prompt`) and hides only `origin.kind=injection` (plus 3 goal-related `system_trigger` names); any other origin renders as a visible user prompt. So injected source noise (claude `<task-notification>`/`[Subagent]`, command blocks, system reminders — classified via `MessageFilter.isNoise`) must be written as `origin.kind=injection` append_messages with NO `turn.prompt`, and excluded from `state.json` title/lastPrompt. Resume: `kimi --session <id>`. A minimal wire (`metadata` + the user/assistant events above) is sufficient for resume — `config.update`(systemPrompt) and `tools.set_active_tools` can be omitted; kimi injects its own on resume (verified). The `ctxmv_migration` dedup marker lives in `state.json`'s `custom` field (never a wire line), and dedup scans `session_index.jsonl` → each `state.json`.
