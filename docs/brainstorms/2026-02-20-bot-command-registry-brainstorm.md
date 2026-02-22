---
title: Shared Bot Command Registry
status: brainstorm
priority: P2
module: computer
tags: [bot-framework, refactor, commands]
issue: 86
---

# Shared Bot Command Registry

## What We're Building

A shared command routing system in the base `BotConnector` class so that platform connectors don't each reimplement the same commands (`/help`, `/new`, `/journal`, `/start`). Today each connector has its own command parsing and handler methods with duplicated logic and inconsistent command names.

### The Problem

| Command | Telegram | Discord | Matrix |
|---------|----------|---------|--------|
| New session | `/new` | `/new` | `!new` |
| Help | `/help` | `/help` | `!help` |
| Journal | `/journal` | `/journal` | `!journal` |
| Start | `/start` (Telegram-specific) | N/A | N/A |

Each connector:
- Parses commands differently (`/slash` vs `!bang` prefix)
- Implements handlers independently (~30-50 lines each, duplicated 3x)
- Has inconsistent error messages and response formatting
- Can't easily add new commands without touching all 3 connectors

## Why This Approach

Move command definitions to the base class with a simple registry pattern. Each connector translates its platform-specific command format (slash, bang, interaction) into a normalized call to the shared handler.

### Design

```python
# In base.py
class BotConnector:
    _commands: dict[str, CommandHandler]  # name -> handler

    def register_command(self, name, handler, description, aliases=None): ...
    async def dispatch_command(self, name, chat_id, sender, args, chat_type): ...
```

- Base class registers shared commands: `new`, `help`, `journal`
- Subclasses can register platform-specific commands (e.g. Telegram's `/start`)
- Command prefix is platform-specific (connector translates before dispatch)
- Handlers return a response string; connector sends it via platform API

### Scope

- Add command registry to `base.py` (~50 lines)
- Extract shared handlers from each connector
- Keep platform-specific registration in subclasses
- No API or Flutter changes

## Key Decisions

- **Registry in base class** — Not a separate module; commands are tightly coupled to connector lifecycle
- **String-based dispatch** — Simple dict lookup, no decorator magic
- **Platform translates prefix** — Base class doesn't know about `/` vs `!`; connector strips prefix before dispatch

## Open Questions

- Should commands support arguments (e.g. `/new philosophy`)? Currently they don't.
- Should we add `/status` command to show session info from within the chat?
