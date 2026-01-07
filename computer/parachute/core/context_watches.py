"""
Context Watch Service - Subscription-based context file relationships.

This module handles:
1. Parsing watch declarations from AGENTS.md frontmatter
2. Maintaining the context_watches table in SQLite
3. Finding watchers when a file is updated (for bubbling)
4. Triggering curator tasks for watched files

Key concepts:
- Watch patterns: Declared in AGENTS.md frontmatter as `watch: ["Projects/*", "../"]`
- Bubbling: When a file is updated, notify files that watch it
- No automatic parent chain: Files must explicitly watch their parents if desired

See docs/AGENTS_CONTEXT_ARCHITECTURE.md for full design.
"""

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import frontmatter

from parachute.db.database import Database

logger = logging.getLogger(__name__)

# File names we look for (in priority order)
CONTEXT_FILE_NAMES = ["AGENTS.md", "CLAUDE.md"]


@dataclass
class WatchDeclaration:
    """A parsed watch declaration from an AGENTS.md file."""

    watcher_path: str  # Path to the AGENTS.md file
    patterns: list[str]  # Watch patterns from frontmatter


@dataclass
class BubbleTarget:
    """A file that should be notified of an update."""

    watcher_path: str  # The file that watches the updated file
    watch_pattern: str  # The pattern that matched


class ContextWatchService:
    """
    Service for managing context file watch relationships.

    Handles:
    - Scanning AGENTS.md files for watch declarations
    - Storing/querying watch relationships in SQLite
    - Finding watchers when files are updated
    """

    def __init__(self, vault_path: Path, db: Database):
        self.vault_path = vault_path
        self.db = db

    # =========================================================================
    # Scanning and Parsing
    # =========================================================================

    async def scan_all_watches(self) -> int:
        """
        Scan all AGENTS.md files in the vault and update watch table.

        Returns the number of watch relationships found.
        """
        # Clear existing watches
        await self.db.clear_all_watches()

        total_watches = 0

        # Find all context files
        for context_file in self._find_all_context_files():
            declaration = self._parse_watch_declaration(context_file)
            if declaration and declaration.patterns:
                await self.db.set_watches_for_context(
                    declaration.watcher_path,
                    declaration.patterns,
                )
                total_watches += len(declaration.patterns)
                logger.debug(
                    f"Registered {len(declaration.patterns)} watches for {declaration.watcher_path}"
                )

        logger.info(f"Scanned watches: {total_watches} total watch relationships")
        return total_watches

    async def update_watches_for_file(self, context_path: str) -> list[str]:
        """
        Update watches for a single AGENTS.md file.

        Call this when a file is edited to refresh its watch declarations.

        Returns the list of patterns now being watched.
        """
        full_path = self.vault_path / context_path
        if not full_path.exists():
            # File was deleted, remove its watches
            await self.db.set_watches_for_context(context_path, [])
            return []

        declaration = self._parse_watch_declaration(full_path)
        patterns = declaration.patterns if declaration else []

        await self.db.set_watches_for_context(context_path, patterns)
        return patterns

    def _find_all_context_files(self) -> list[Path]:
        """Find all AGENTS.md and CLAUDE.md files in the vault."""
        context_files: list[Path] = []

        # Check root
        for name in CONTEXT_FILE_NAMES:
            root_file = self.vault_path / name
            if root_file.exists():
                context_files.append(root_file)
                break  # Only use the first one found

        # Walk the vault
        for folder in self.vault_path.rglob("*"):
            if not folder.is_dir():
                continue

            # Skip hidden and common non-content folders
            relative = folder.relative_to(self.vault_path)
            parts = relative.parts
            if any(p.startswith(".") for p in parts):
                continue
            if any(p in ("node_modules", "__pycache__", "venv", ".git", "build") for p in parts):
                continue

            for name in CONTEXT_FILE_NAMES:
                context_file = folder / name
                if context_file.exists():
                    context_files.append(context_file)
                    break  # Only use the first one found

        return context_files

    def _parse_watch_declaration(self, file_path: Path) -> Optional[WatchDeclaration]:
        """
        Parse watch declarations from an AGENTS.md file's frontmatter.

        Expected format:
        ---
        watch:
          - "Projects/*"
          - "../"
        ---
        """
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                post = frontmatter.load(f)

            watch_value = post.metadata.get("watch", [])

            # Handle string or list
            if isinstance(watch_value, str):
                patterns = [watch_value]
            elif isinstance(watch_value, list):
                patterns = [str(p) for p in watch_value if p]
            else:
                patterns = []

            # Normalize the watcher path
            relative_path = str(file_path.relative_to(self.vault_path))

            return WatchDeclaration(
                watcher_path=relative_path,
                patterns=patterns,
            )

        except Exception as e:
            logger.warning(f"Error parsing watch declaration from {file_path}: {e}")
            return None

    # =========================================================================
    # Querying Watches
    # =========================================================================

    async def find_watchers(self, updated_path: str) -> list[BubbleTarget]:
        """
        Find all context files that watch a given path.

        This is the key method for bubbling: when an AGENTS.md is updated,
        find all files that declared they watch it.

        Args:
            updated_path: The path that was updated (e.g., "Projects/parachute/AGENTS.md")

        Returns:
            List of BubbleTarget objects for files that watch this path
        """
        targets: list[BubbleTarget] = []

        # Get the folder path (strip the filename)
        if updated_path.endswith("/AGENTS.md") or updated_path.endswith("/CLAUDE.md"):
            folder_path = "/".join(updated_path.split("/")[:-1])
        elif updated_path == "AGENTS.md" or updated_path == "CLAUDE.md":
            folder_path = ""
        else:
            folder_path = updated_path

        # Get all watches from DB
        all_watches = await self.db.get_all_watches()

        for watch in all_watches:
            watcher_path = watch["watcher_path"]
            pattern = watch["watch_pattern"]

            # Don't watch yourself
            if watcher_path == updated_path:
                continue

            # Get the watcher's folder for resolving relative patterns
            if "/" in watcher_path:
                watcher_folder = "/".join(watcher_path.split("/")[:-1])
            else:
                watcher_folder = ""

            # Check if this pattern matches the updated path
            if self._pattern_matches(pattern, folder_path, watcher_folder):
                targets.append(BubbleTarget(
                    watcher_path=watcher_path,
                    watch_pattern=pattern,
                ))

        return targets

    def _pattern_matches(
        self, pattern: str, target_folder: str, watcher_folder: str
    ) -> bool:
        """
        Check if a watch pattern matches a target folder.

        Handles:
        - Exact matches: "Projects/parachute"
        - Glob patterns: "Projects/*", "**/*"
        - Relative paths: "../" (resolved from watcher's location)
        """
        # Handle relative patterns (../, ./)
        if pattern.startswith("../") or pattern.startswith("./"):
            # Resolve relative to watcher's folder
            if watcher_folder:
                watcher_parts = watcher_folder.split("/")
            else:
                watcher_parts = []

            pattern_parts = pattern.split("/")
            resolved_parts = list(watcher_parts)

            for part in pattern_parts:
                if part == "..":
                    if resolved_parts:
                        resolved_parts.pop()
                elif part == ".":
                    continue
                elif part:
                    resolved_parts.append(part)

            resolved_pattern = "/".join(resolved_parts)

            # After resolving, check for exact match or glob
            if "*" in resolved_pattern:
                return fnmatch.fnmatch(target_folder, resolved_pattern)
            else:
                return target_folder == resolved_pattern

        # Handle glob patterns
        if "*" in pattern:
            return fnmatch.fnmatch(target_folder, pattern)

        # Exact match
        return target_folder == pattern

    async def get_watch_stats(self) -> dict:
        """Get statistics about watch relationships."""
        all_watches = await self.db.get_all_watches()

        watchers = set()
        patterns = set()
        for watch in all_watches:
            watchers.add(watch["watcher_path"])
            patterns.add(watch["watch_pattern"])

        return {
            "total_watches": len(all_watches),
            "unique_watchers": len(watchers),
            "unique_patterns": len(patterns),
            "watches": all_watches,
        }


# =========================================================================
# File System Watcher
# =========================================================================

class ContextFileWatcher:
    """
    Watches for changes to AGENTS.md files in the vault.

    When a file is modified (not by curator), triggers:
    1. Re-scan of watch declarations for that file
    2. Bubbling to files that watch it
    """

    def __init__(self, vault_path: Path, db: Database):
        self.vault_path = vault_path
        self.db = db
        self._observer = None
        self._running = False

    def start(self) -> None:
        """Start watching for file changes."""
        try:
            from watchdog.observers import Observer
            from watchdog.events import FileSystemEventHandler, FileModifiedEvent

            class AgentsMdHandler(FileSystemEventHandler):
                def __init__(handler_self, watcher: "ContextFileWatcher"):
                    handler_self.watcher = watcher

                def on_modified(handler_self, event):
                    if event.is_directory:
                        return

                    # Only care about AGENTS.md and CLAUDE.md
                    file_path = Path(event.src_path)
                    if file_path.name not in CONTEXT_FILE_NAMES:
                        return

                    # Get relative path
                    try:
                        relative_path = str(file_path.relative_to(handler_self.watcher.vault_path))
                    except ValueError:
                        return

                    logger.info(f"Detected change to context file: {relative_path}")

                    # Schedule async handling
                    import asyncio
                    try:
                        loop = asyncio.get_running_loop()
                        loop.create_task(
                            handler_self.watcher._handle_file_change(relative_path)
                        )
                    except RuntimeError:
                        # No running loop - skip (probably shutting down)
                        pass

            self._observer = Observer()
            self._observer.schedule(
                AgentsMdHandler(self),
                str(self.vault_path),
                recursive=True,
            )
            self._observer.start()
            self._running = True
            logger.info(f"Started watching for AGENTS.md changes in {self.vault_path}")

        except ImportError:
            logger.warning("watchdog not installed - file watching disabled")
        except Exception as e:
            logger.error(f"Failed to start file watcher: {e}")

    def stop(self) -> None:
        """Stop watching for file changes."""
        if self._observer:
            self._observer.stop()
            self._observer.join(timeout=5)
            self._observer = None
        self._running = False
        logger.info("Stopped file watcher")

    async def _handle_file_change(self, relative_path: str) -> None:
        """Handle a change to an AGENTS.md file."""
        try:
            # Re-scan this file's watch declarations
            watch_service = await get_watch_service()
            new_patterns = await watch_service.update_watches_for_file(relative_path)
            logger.debug(f"Updated watches for {relative_path}: {new_patterns}")

            # Trigger bubbling for files that watch this one
            watchers = await watch_service.find_watchers(relative_path)
            if watchers:
                logger.info(f"File {relative_path} is watched by {len(watchers)} files")

                # Queue curator tasks for watchers
                # Note: We don't have a session ID here, so we'll use a special marker
                for target in watchers:
                    logger.info(
                        f"Bubbling from direct edit: {relative_path} -> {target.watcher_path}"
                    )
                    # TODO: Consider creating a lightweight notification mechanism
                    # For now, we just log the relationship - full bubbling requires a session context

        except Exception as e:
            logger.error(f"Error handling file change for {relative_path}: {e}")


# =========================================================================
# Module-level helpers
# =========================================================================

_watch_service: Optional[ContextWatchService] = None
_file_watcher: Optional[ContextFileWatcher] = None


async def get_watch_service() -> ContextWatchService:
    """Get the global watch service instance."""
    global _watch_service
    if _watch_service is None:
        raise RuntimeError("Watch service not initialized")
    return _watch_service


async def init_watch_service(vault_path: Path, db: Database) -> ContextWatchService:
    """Initialize the global watch service and scan for watches."""
    global _watch_service, _file_watcher

    _watch_service = ContextWatchService(vault_path, db)

    # Initial scan
    await _watch_service.scan_all_watches()

    # Start file watcher for direct edits
    _file_watcher = ContextFileWatcher(vault_path, db)
    _file_watcher.start()

    return _watch_service


async def stop_watch_service() -> None:
    """Stop the watch service and file watcher."""
    global _watch_service, _file_watcher

    if _file_watcher:
        _file_watcher.stop()
        _file_watcher = None

    _watch_service = None
