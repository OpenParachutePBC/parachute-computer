---
title: "feat: Shared bot command registry"
type: feat
date: 2026-02-23
issue: 86
---

# feat: Shared bot command registry

## Overview

Add a command registry to `BotConnector` base class that centralises the `/new`, `/journal`, and `/help` handler logic currently duplicated across Telegram, Discord, and Matrix connectors. Each connector retains its platform-specific command registration mechanism and response formatting; the business logic lives once in the base class.

## Problem Statement

Command handler logic is duplicated ~3× across three connectors:

| Command | Telegram | Discord | Matrix |
|---------|----------|---------|--------|
| New session | `/new` | `/new` (slash cmd) | `!new` |
| Help | `/help` | _(missing)_ | `!help` |
| Journal | `/journal` | `/journal` (slash cmd) | `!journal` |

Each connector:

- Implements `new` and `journal` with identical DB/session logic (~30–40 lines each, duplicated 3×)
- Has no consistent help command (Discord has no `/help` at all)
- Requires touching all 3 files to add or change a command
- Uses different prefixes (`/` vs `!`) for the same underlying behaviour

Matrix is the outlier: it manually parses `!command` inline in `_handle_command` (lines 574–627) with a chain of `elif` branches. Telegram and Discord use framework-level routing (`CommandHandler`, `app_commands.CommandTree`) but still duplicate the handler bodies.

## Proposed Solution

Add three members to `BotConnector`:

```python
# base.py
class BotConnector(ABC):
    def register_command(
        self, name: str, handler: Callable, description: str,
        aliases: list[str] | None = None
    ) -> None: ...

    async def dispatch_command(
        self, name: str, chat_id: str, sender: str, args: list[str]
    ) -> str | None: ...

    def _register_shared_commands(self) -> None: ...  # called from __init__
```

**Handler contract:** `async (chat_id: str, sender: str, args: list[str]) -> str`
Handlers return a plain-text/markdown response string. Each connector sends it via its own platform API.

**Authorization stays in each connector.** Each platform already calls `is_user_allowed()` before dispatching to the orchestrator; the same gate applies before `dispatch_command`. Nothing changes here.

**Platform-specific commands** (Telegram's `/start`, `/ask`, `/init`) remain in `TelegramConnector`. They register with the base registry in `__init__` so that `_shared_cmd_help` lists them in the output, but their actual execution logic stays on the subclass.

## Technical Approach

### Step 1 — Registry infrastructure (`base.py`)

Add a private dataclass and two public methods:

```python
# computer/parachute/connectors/base.py

import dataclasses
from collections.abc import Awaitable, Callable

@dataclasses.dataclass
class _CommandEntry:
    name: str
    handler: Callable[..., Awaitable[str]]
    description: str
    aliases: list[str] = dataclasses.field(default_factory=list)
```

In `BotConnector.__init__` (after existing initialisation):
```python
self._commands: dict[str, _CommandEntry] = {}
self._register_shared_commands()
```

New methods:
```python
def register_command(
    self, name: str, handler: Callable, description: str,
    aliases: list[str] | None = None,
) -> None:
    entry = _CommandEntry(name=name, handler=handler, description=description, aliases=aliases or [])
    self._commands[name] = entry
    for alias in (aliases or []):
        self._commands[alias] = entry

async def dispatch_command(
    self, name: str, chat_id: str, sender: str, args: list[str],
) -> str | None:
    """Dispatch a normalised command name. Returns response string, or None if unknown."""
    entry = self._commands.get(name)
    if entry is None:
        return None
    return await entry.handler(chat_id, sender, args)
```

### Step 2 — Shared handlers (`base.py`)

```python
def _register_shared_commands(self) -> None:
    self.register_command("new", self._shared_cmd_new, "Start a new conversation")
    self.register_command("journal", self._shared_cmd_journal, "Add a journal entry", aliases=["j"])
    self.register_command("help", self._shared_cmd_help, "Show available commands")

async def _shared_cmd_new(self, chat_id: str, sender: str, args: list[str]) -> str:
    db = getattr(self.server, "database", None)
    if db:
        session = await db.get_session_by_bot_link(self.platform, chat_id)
        if session:
            await db.archive_session(session.id)
    return "Starting fresh! What would you like to work on?"

async def _shared_cmd_journal(self, chat_id: str, sender: str, args: list[str]) -> str:
    content = " ".join(args) if args else ""
    if not content:
        return "Please provide content: `journal your entry here`"
    daily_create = getattr(self.server, "create_journal_entry", None)
    if not daily_create:
        return "Daily module not available."
    result = await daily_create(
        content=content, source=self.platform,
        metadata={"chat_id": chat_id, "sender": sender},
    )
    return f"Journal entry saved: {result.title}"

async def _shared_cmd_help(self, chat_id: str, sender: str, args: list[str]) -> str:
    lines = ["**Available commands:**"]
    seen: set[int] = set()
    for entry in self._commands.values():
        if id(entry) not in seen:
            seen.add(id(entry))
            alias_str = f" ({', '.join(entry.aliases)})" if entry.aliases else ""
            lines.append(f"• **{entry.name}**{alias_str} — {entry.description}")
    return "\n".join(lines)
```

### Step 3 — Wire Telegram (`telegram.py`)

Telegram command registration via `CommandHandler` stays unchanged (framework-level, lines 83–98). The handler method bodies are replaced with registry delegation:

```python
# telegram.py — replace body of _cmd_new, _cmd_journal, _cmd_help

async def _cmd_new(self, update, context) -> None:
    user_id = str(update.effective_user.id)
    chat_id = str(update.effective_chat.id)
    if not self.is_user_allowed(user_id):
        response = await self.handle_unknown_user(user_id, chat_id, self.platform)
        await update.message.reply_text(response)
        return
    response = await self.dispatch_command("new", chat_id, user_id, context.args or [])
    await update.message.reply_text(response)

async def _cmd_journal(self, update, context) -> None:
    user_id = str(update.effective_user.id)
    chat_id = str(update.effective_chat.id)
    if not self.is_user_allowed(user_id):
        response = await self.handle_unknown_user(user_id, chat_id, self.platform)
        await update.message.reply_text(response)
        return
    response = await self.dispatch_command("journal", chat_id, user_id, context.args or [])
    await update.message.reply_text(response)

async def _cmd_help(self, update, context) -> None:
    chat_id = str(update.effective_chat.id)
    user_id = str(update.effective_user.id)
    response = await self.dispatch_command("help", chat_id, user_id, [])
    await update.message.reply_text(response)
```

Platform-specific Telegram commands (`start`, `ask`, `init`) register with the base registry in `TelegramConnector.__init__` (after `super().__init__()`) so `_shared_cmd_help` lists them. Their handler bodies stay unchanged:

```python
# In TelegramConnector.__init__ (after super().__init__()):
self.register_command("start", self._cmd_start, "Start or link your account")
self.register_command("ask", self._cmd_ask, "Send a one-off question")
self.register_command("init", self._cmd_init, "Initialise workspace")
```

### Step 4 — Wire Discord (`discord_bot.py`)

Discord's slash commands (registered in `_setup_client`, lines 105–121) delegate to registry. The `_handle_new` and `_handle_journal` methods shrink to thin wrappers:

```python
# discord_bot.py — replace _handle_new, _handle_journal bodies

async def _handle_new(self, interaction: discord.Interaction) -> None:
    user_id = str(interaction.user.id)
    chat_id = str(interaction.channel_id)
    if not self.is_user_allowed(user_id):
        await interaction.response.send_message("You don't have access.", ephemeral=True)
        return
    await interaction.response.defer(ephemeral=True)
    response = await self.dispatch_command("new", chat_id, user_id, [])
    await interaction.followup.send(response)

async def _handle_journal(self, interaction: discord.Interaction, entry: str) -> None:
    user_id = str(interaction.user.id)
    chat_id = str(interaction.channel_id)
    if not self.is_user_allowed(user_id):
        await interaction.response.send_message("You don't have access.", ephemeral=True)
        return
    await interaction.response.defer(ephemeral=True)
    response = await self.dispatch_command("journal", chat_id, user_id, entry.split() if entry else [])
    await interaction.followup.send(response)
```

Discord's `/chat` command (`_handle_chat`) is the main text entry mechanism — it stays untouched.

### Step 5 — Wire Matrix (`matrix_bot.py`)

Matrix's `_handle_command` (lines 574–627) replaces its manual `elif` chain with a single registry dispatch:

```python
# matrix_bot.py — replace body of _handle_command

async def _handle_command(
    self, room_id: str, sender: str, message_text: str, chat_type: str,
) -> bool:
    parts = message_text.strip().split(maxsplit=1)
    command = parts[0].lstrip("!").lower()  # !new → new, !help → help
    args = parts[1].split() if len(parts) > 1 else []

    response = await self.dispatch_command(command, room_id, sender, args)
    if response is None:
        return False
    plain, html = claude_to_matrix(response)
    await self._send_room_message(room_id, plain, html)
    return True
```

The ~50-line `elif` block is removed entirely.

### Step 6 — Tests (`test_bot_connectors.py`)

New test class `TestCommandRegistry`:

| Test | What it verifies |
|------|-----------------|
| `test_register_and_dispatch` | Registered handler is called, returns response string |
| `test_unknown_command_returns_none` | `dispatch_command("xyz", ...)` → `None` |
| `test_aliases_dispatch_correctly` | `dispatch_command("j", ...)` routes to `_shared_cmd_journal` |
| `test_shared_cmd_new_archives_session` | Mock db with existing session → `archive_session` called |
| `test_shared_cmd_new_no_existing_session` | No session → no error, returns fresh-start message |
| `test_shared_cmd_journal_empty_args` | Empty args → returns usage hint |
| `test_shared_cmd_journal_no_daily_module` | `server` has no `create_journal_entry` → returns module-unavailable message |
| `test_shared_cmd_journal_creates_entry` | Mock `daily_create` called with correct args, returns title |
| `test_shared_cmd_help_lists_all_commands` | All registered command names appear in output |
| `test_matrix_dispatch_strips_bang_prefix` | `_handle_command("!new", ...)` dispatches `new` via registry |

## Acceptance Criteria

- [x] `BotConnector` has `_commands: dict`, `register_command()`, `dispatch_command()`
- [x] Shared handlers `_shared_cmd_new`, `_shared_cmd_journal`, `_shared_cmd_help` in base class
- [x] Telegram `_cmd_new`, `_cmd_journal`, `_cmd_help` delegate to `dispatch_command()`
- [x] Discord `_handle_new`, `_handle_journal` delegate to `dispatch_command()`
- [x] Matrix `_handle_command` uses registry; manual `elif` chain removed
- [x] `_shared_cmd_help` dynamically lists all registered commands including platform-specific ones
- [x] Platform-specific commands (Telegram: `start`, `ask`, `init`) registered in registry for help visibility
- [x] All 153 existing bot connector tests still pass (170 total with 17 new)
- [x] New `TestCommandRegistry` class with ≥ 10 tests covering registry and shared handler logic (17 tests)
- [x] No new ruff lint errors

## Scope Notes

- No API or Flutter changes
- No changes to authorization logic (`is_user_allowed`, `handle_unknown_user`)
- No changes to `_route_to_chat` — the orchestrator event loop is a separate refactor (#82)
- Telegram `/start`, `/ask`, `/init` execution logic stays in `TelegramConnector`
- Discord `/chat` slash command stays as-is (it's the main text input, not a shared command)
- Command arguments are supported (e.g., `/journal my entry text`) — list passed as `args`
- `/status` command (open question from brainstorm) is explicitly out of scope; can be added later via `register_command`

## References

- Brainstorm: `docs/brainstorms/2026-02-20-bot-command-registry-brainstorm.md`
- `computer/parachute/connectors/base.py` — `BotConnector` base class, `GroupHistoryBuffer`
- `computer/parachute/connectors/telegram.py:83` — `_build_app` framework `CommandHandler` registration
- `computer/parachute/connectors/telegram.py:148` — `_cmd_start`, `_cmd_new`, `_cmd_help`, `_cmd_journal`
- `computer/parachute/connectors/discord_bot.py:96` — `_setup_client` slash command tree
- `computer/parachute/connectors/discord_bot.py:393` — `_handle_new`, `_handle_journal`
- `computer/parachute/connectors/matrix_bot.py:574` — `_handle_command` manual dispatch (to be replaced)
- `computer/tests/unit/test_bot_connectors.py:374` — `_make_test_connector` factory pattern for tests
