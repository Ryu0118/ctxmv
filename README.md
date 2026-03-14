# ctxmv

A CLI tool to migrate conversation sessions between AI coding agents.

Supports **Claude Code**, **Codex**, and **Cursor** (CLI agent via `cursor-agent`, not the GUI app).

## Features

- 🔀 Migrate sessions between any pair of agents in native format (resume-compatible)
- 📋 List sessions across all agents in a unified table
- 💬 Show conversation messages with role-colored output

## Install

### Nest ([mtj0928/nest](https://github.com/mtj0928/nest))

```bash
nest install Ryu0118/ctxmv
```

### Mise ([jdx/mise](https://github.com/jdx/mise))

```bash
mise use -g ubi:Ryu0118/ctxmv
```

### Nix

```bash
nix run github:Ryu0118/ctxmv
```

Or add to your `flake.nix`:

```nix
inputs.ctxmv.url = "github:Ryu0118/ctxmv";
```

### Build from source

Requires Swift 6.0+ and macOS 15+.

```bash
git clone https://github.com/Ryu0118/ctxmv.git
cd ctxmv
swift run ctxmv <subcommand>
```

## Usage

```bash
# Claude Code → Codex
ctxmv <session-id> --to codex

# Codex → Claude Code
ctxmv <session-id> --to claude-code

# Any → Cursor
ctxmv <session-id> --to cursor
```

After migration, the tool prints the resume command:

```
✅ Session written to: /path/to/session
To resume:
  cd /your/project
  codex resume <new-session-id>
```

> **Note:** Cursor may not render migrated past messages in TUI immediately after resume. However, conversation context is preserved and past messages are still available to the agent.

### List sessions

```bash
# List all sessions across all agents
ctxmv list

# Filter by agent
ctxmv list --source claude-code
ctxmv list --source codex
ctxmv list --source cursor

# Filter by project path
ctxmv list --project /path/to/project

# Limit results
ctxmv list --limit 50
```

### Show session messages

```bash
# Show messages for a session (full or prefix ID)
ctxmv show <session-id>

# Restrict search to a specific agent
ctxmv show <session-id> --source claude-code

# Show raw content without compacting XML-like blocks
ctxmv show <session-id> --raw

# Show only the last N messages
ctxmv show <session-id> --limit 20

# Show all messages, bypassing large-session protection
ctxmv show <session-id> --all
```

## License

MIT
