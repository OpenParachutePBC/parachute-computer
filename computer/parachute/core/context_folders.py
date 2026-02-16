"""
Context Folders - Folder-based context system with AGENTS.md hierarchy.

This module handles:
1. Discovering folders with AGENTS.md or CLAUDE.md files
2. Building parent chains for selected folders
3. Loading context content from the chain
4. Providing context info to agents

See docs/AGENTS_CONTEXT_ARCHITECTURE.md for full design.
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# File names we look for (in priority order)
CONTEXT_FILE_NAMES = ["AGENTS.md", "CLAUDE.md"]

# Rough estimate: 4 chars per token
CHARS_PER_TOKEN = 4


@dataclass
class ContextFolder:
    """A folder that contains context (AGENTS.md or CLAUDE.md)."""

    path: str  # Relative to vault (e.g., "Projects/parachute")
    context_file: str  # Which file exists: "AGENTS.md" or "CLAUDE.md"
    has_agents_md: bool = False
    has_claude_md: bool = False

    @property
    def display_name(self) -> str:
        """Human-readable name from the folder path."""
        if not self.path:
            return "Root"
        return self.path.split("/")[-1].replace("-", " ").replace("_", " ").title()


@dataclass
class ContextFile:
    """A loaded context file with content and metadata."""

    path: str  # Relative path to the file (e.g., "Projects/parachute/AGENTS.md")
    folder_path: str  # Folder path (e.g., "Projects/parachute")
    level: str  # "root", "parent", or "direct"
    content: str = ""
    tokens: int = 0
    exists: bool = True


@dataclass
class ContextChain:
    """The full chain of context files for a set of selected folders."""

    files: list[ContextFile] = field(default_factory=list)
    total_tokens: int = 0
    truncated: bool = False

    @property
    def file_paths(self) -> list[str]:
        """List of file paths in the chain."""
        return [f.path for f in self.files if f.exists]


class ContextFolderService:
    """Service for discovering and loading folder-based context."""

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path

    def discover_folders(self) -> list[ContextFolder]:
        """
        Discover all folders in the vault that have AGENTS.md or CLAUDE.md.

        Returns folders sorted by path depth (shallower first).
        """
        folders: list[ContextFolder] = []

        # Check root
        root_file = self._find_context_file(self.vault_path)
        if root_file:
            folders.append(ContextFolder(
                path="",
                context_file=root_file,
                has_agents_md=(self.vault_path / "AGENTS.md").exists(),
                has_claude_md=(self.vault_path / "CLAUDE.md").exists(),
            ))

        # Walk the vault looking for context files
        for folder in self.vault_path.rglob("*"):
            if not folder.is_dir():
                continue

            # Skip hidden folders and common non-content folders
            relative = folder.relative_to(self.vault_path)
            parts = relative.parts
            if any(p.startswith(".") for p in parts):
                continue
            if any(p in ("node_modules", "__pycache__", "venv", ".git", "build") for p in parts):
                continue

            context_file = self._find_context_file(folder)
            if context_file:
                folders.append(ContextFolder(
                    path=str(relative),
                    context_file=context_file,
                    has_agents_md=(folder / "AGENTS.md").exists(),
                    has_claude_md=(folder / "CLAUDE.md").exists(),
                ))

        # Sort by path depth
        folders.sort(key=lambda f: (len(f.path.split("/")) if f.path else 0, f.path))

        return folders

    def _find_context_file(self, folder: Path) -> Optional[str]:
        """Find which context file exists in a folder (AGENTS.md preferred)."""
        for name in CONTEXT_FILE_NAMES:
            if (folder / name).exists():
                return name
        return None

    def build_chain(
        self,
        selected_folders: list[str],
        max_tokens: int = 50000,
        include_parent_chain: bool = False,
    ) -> ContextChain:
        """
        Build the context chain for selected folders.

        By default (include_parent_chain=False), this ONLY loads the directly
        selected folders' AGENTS.md files. Files must explicitly declare what
        they watch using frontmatter `watch:` declarations.

        If include_parent_chain=True (legacy mode), includes:
        1. Root AGENTS.md (always, if exists)
        2. Parent folders' AGENTS.md for each selected folder
        3. The selected folders' AGENTS.md files

        Files are deduplicated and ordered from root to leaves.
        """
        chain = ContextChain()
        seen_paths: set[str] = set()
        total_chars = 0
        max_chars = max_tokens * CHARS_PER_TOKEN

        # Collect all folder paths we need to check
        all_folders: list[tuple[str, str]] = []  # (folder_path, level)

        if include_parent_chain:
            # Legacy mode: include root and parent chain
            all_folders.append(("", "root"))

            for folder_path in selected_folders:
                if not folder_path:
                    continue

                # Add parent folders
                parts = folder_path.split("/")
                for i in range(len(parts)):
                    parent_path = "/".join(parts[:i+1])
                    level = "direct" if i == len(parts) - 1 else "parent"
                    all_folders.append((parent_path, level))
        else:
            # New mode: only load directly selected folders
            for folder_path in selected_folders:
                # Empty string means root folder
                all_folders.append((folder_path, "direct"))

        # Deduplicate and sort by depth
        unique_folders: dict[str, str] = {}  # path -> level (prefer "direct" over "parent")
        for folder_path, level in all_folders:
            if folder_path not in unique_folders or level == "direct":
                unique_folders[folder_path] = level

        sorted_folders = sorted(
            unique_folders.items(),
            key=lambda x: (len(x[0].split("/")) if x[0] else 0, x[0])
        )

        # Load each folder's context file
        for folder_path, level in sorted_folders:
            if folder_path in seen_paths:
                continue
            seen_paths.add(folder_path)

            folder_full_path = self.vault_path / folder_path if folder_path else self.vault_path
            context_filename = self._find_context_file(folder_full_path)

            if not context_filename:
                continue

            file_path = folder_full_path / context_filename
            relative_file_path = f"{folder_path}/{context_filename}" if folder_path else context_filename

            try:
                content = file_path.read_text(encoding="utf-8")
                content_chars = len(content)

                # Check token budget
                if total_chars + content_chars > max_chars:
                    # Truncate this file
                    remaining = max_chars - total_chars
                    if remaining > 100:  # Only include if we can show something meaningful
                        content = content[:remaining] + "\n[...truncated]"
                        chain.truncated = True
                    else:
                        chain.truncated = True
                        continue

                total_chars += len(content)
                tokens = len(content) // CHARS_PER_TOKEN

                chain.files.append(ContextFile(
                    path=relative_file_path,
                    folder_path=folder_path,
                    level=level,
                    content=content,
                    tokens=tokens,
                    exists=True,
                ))

            except Exception as e:
                logger.warning(f"Error reading context file {file_path}: {e}")
                chain.files.append(ContextFile(
                    path=relative_file_path,
                    folder_path=folder_path,
                    level=level,
                    exists=False,
                ))

        chain.total_tokens = total_chars // CHARS_PER_TOKEN
        return chain

    def format_chain_for_prompt(
        self, chain: ContextChain, working_directory: str | None = None
    ) -> str:
        """
        Format the context chain for inclusion in a system prompt.

        Returns markdown-formatted context with section headers.
        When working_directory is set, labels the section as reference context.
        """
        if not chain.files:
            return ""

        valid_files = [f for f in chain.files if f.exists and f.content]
        if not valid_files:
            return ""

        parts = []
        file_count = len(valid_files)
        token_count = chain.total_tokens

        if working_directory:
            parts.append("## Reference Context")
            parts.append(
                f"The following context has been loaded as supplementary reference "
                f"({file_count} files, ~{token_count} tokens):\n"
            )
        else:
            parts.append("## Project Knowledge")
            parts.append(
                f"The following context has been loaded for your reference "
                f"({file_count} files, ~{token_count} tokens):\n"
            )

        for ctx_file in valid_files:
            parts.append(f"## {ctx_file.path}")
            parts.append("")
            parts.append(ctx_file.content)
            parts.append("")
            parts.append("---")
            parts.append("")

        return "\n".join(parts)

def get_context_folder_service(vault_path: Path) -> ContextFolderService:
    """Get a ContextFolderService instance."""
    return ContextFolderService(vault_path)
