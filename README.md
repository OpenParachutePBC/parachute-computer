# Parachute Computer

Open & interoperable extended mind technology. A personal AI computer that runs locally, connects your tools, and keeps your data yours.

## Quick Start

### Server

```bash
cd computer
./install.sh
```

### App

```bash
cd app
flutter run -d macos
```

See [computer/README.md](computer/README.md) for full server docs and [app/README.md](app/README.md) for app docs.

## What's in here

| Directory | What | Stack |
|-----------|------|-------|
| `computer/` | AI orchestration server - modules, sandboxing, bot connectors | Python, FastAPI, Claude SDK |
| `app/` | Unified mobile/desktop app - journaling, chat, vault, brain | Flutter, Riverpod |

## Modules

Parachute Computer loads modules at runtime:

- **Chat** - AI conversations with workspace sandboxing and trust levels
- **Daily** - Voice journaling with offline support and AI reflections
- **Brain** - Knowledge graph across all your data

## Principles

- **Interoperable** - Works with your existing tools, no lock-in
- **Intuitive** - Natural interfaces with guidance and guardrails
- **Integrated** - One cohesive system, not a bag of parts

## License

Open source. Built by [Open Parachute, PBC](https://openparachute.io).
