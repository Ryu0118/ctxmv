# ctxmv - A CLI tool to migrate conversation sessions between AI coding agents.

[![Language](https://img.shields.io/badge/Language-Swift-F05138?style=flat-square)](https://www.swift.org)
[![License](https://img.shields.io/badge/License-MIT-007ec6?style=flat-square)](LICENSE)
[![release](https://img.shields.io/github/v/release/Ryu0118/ctxmv?style=flat-square)](https://github.com/Ryu0118/ctxmv/releases/latest)
[![Follow @ryu_hu03](https://img.shields.io/badge/Follow-%40ryu__hu03-ffffff?style=flat-square&logo=x&logoColor=000000&labelColor=ffffff&color=ffffff)](https://x.com/ryu_hu03)

✨ **You no longer need to suffer through rate limits: when one coding agent hits its limit, migrate the session to another and keep going.**

| Claude Code | Codex | Cursor |
|:-:|:-:|:-:|
| ![Claude Code](assets/demo-claude-code.png) | ![Codex](assets/demo-codex.png) | ![Cursor](assets/demo-cursor.png) |

## Features

- 🔀 Migrate sessions between any pair of agents (resume-compatible)
- 📋 List sessions across all agents in a unified table
- 💬 Show conversation messages with role-colored output

### Supports

- Claude Code
- Codex
- Cursor (CLI agent via `cursor-agent`, not the GUI app)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Ryu0118/ctxmv/main/install.sh | bash
```

To update, run the same command. It skips the download if already up-to-date.

```bash
# Install a specific version
curl -fsSL https://raw.githubusercontent.com/Ryu0118/ctxmv/main/install.sh | VERSION=0.1.0 bash

# Force reinstall
curl -fsSL https://raw.githubusercontent.com/Ryu0118/ctxmv/main/install.sh | FORCE=1 bash
```

### Other methods

#### Nest ([mtj0928/nest](https://github.com/mtj0928/nest))

```bash
nest install Ryu0118/ctxmv
```

#### Mise ([jdx/mise](https://github.com/jdx/mise))

```bash
mise use -g ubi:Ryu0118/ctxmv
```

#### Build from source

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
