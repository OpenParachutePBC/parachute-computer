"""
Vault file operation utilities.
"""

import fnmatch
import os
from pathlib import Path
from typing import Any, Optional

import frontmatter


async def read_document(
    vault_path: Path, relative_path: str
) -> Optional[dict[str, Any]]:
    """
    Read a markdown document with frontmatter.

    Returns dict with 'path', 'frontmatter', 'body', 'raw' keys.
    """
    full_path = vault_path / relative_path

    try:
        with open(full_path, "r", encoding="utf-8") as f:
            content = f.read()

        post = frontmatter.loads(content)
        return {
            "path": relative_path,
            "frontmatter": dict(post.metadata),
            "body": post.content,
            "raw": content,
        }
    except FileNotFoundError:
        return None
    except Exception:
        return None


async def write_document(
    vault_path: Path,
    relative_path: str,
    body: str,
    metadata: Optional[dict[str, Any]] = None,
) -> None:
    """Write a markdown document with optional frontmatter."""
    full_path = vault_path / relative_path

    # Ensure parent directory exists
    full_path.parent.mkdir(parents=True, exist_ok=True)

    post = frontmatter.Post(body, **(metadata or {}))
    content = frontmatter.dumps(post)

    with open(full_path, "w", encoding="utf-8") as f:
        f.write(content)


async def list_vault_files(
    vault_path: Path,
    directory: str = "",
    extension: str = ".md",
    max_depth: int = 20,
) -> list[str]:
    """
    List files in vault with specified extension.

    Returns list of relative paths.
    """
    files = []
    start_path = vault_path / directory if directory else vault_path

    def _walk(current_path: Path, depth: int) -> None:
        if depth > max_depth:
            return

        try:
            for entry in current_path.iterdir():
                if entry.name.startswith("."):
                    continue

                if entry.is_dir():
                    _walk(entry, depth + 1)
                elif entry.suffix == extension:
                    rel_path = entry.relative_to(vault_path)
                    files.append(str(rel_path))
        except PermissionError:
            pass

    _walk(start_path, 0)
    return files


def matches_pattern(path: str, pattern: str) -> bool:
    """Check if a path matches a glob pattern."""
    # Handle ** for recursive matching
    if "**" in pattern:
        # Convert ** glob to regex
        # ** matches any number of directories (including zero)
        import re

        # Escape special regex characters except * and ?
        regex_pattern = ""
        i = 0
        while i < len(pattern):
            if i + 1 < len(pattern) and pattern[i : i + 2] == "**":
                # ** matches any path segment(s)
                regex_pattern += ".*"
                i += 2
            elif pattern[i] == "*":
                # * matches within a path segment (no /)
                regex_pattern += "[^/]*"
                i += 1
            elif pattern[i] == "?":
                regex_pattern += "[^/]"
                i += 1
            elif pattern[i] in ".^$+{}[]|()":
                regex_pattern += "\\" + pattern[i]
                i += 1
            else:
                regex_pattern += pattern[i]
                i += 1

        return bool(re.fullmatch(regex_pattern, path))

    return fnmatch.fnmatch(path, pattern)


def matches_patterns(path: str, patterns: list[str]) -> bool:
    """Check if a path matches any of the patterns."""
    if "*" in patterns:
        return True

    for pattern in patterns:
        if matches_pattern(path, pattern):
            return True

    return False


def validate_path(vault_path: Path, relative_path: str) -> bool:
    """
    Validate that a path is safe (no directory traversal).

    Returns True if the path is valid.
    """
    # Reject paths with ..
    if ".." in relative_path:
        return False

    # Resolve and check it's still within vault
    try:
        full_path = (vault_path / relative_path).resolve()
        return full_path.is_relative_to(vault_path.resolve())
    except (ValueError, RuntimeError):
        return False


def get_vault_stats(vault_path: Path) -> dict[str, Any]:
    """Get statistics about the vault."""
    stats = {
        "path": str(vault_path),
        "exists": vault_path.exists(),
        "modules": [],
        "total_files": 0,
        "total_size": 0,
    }

    if not vault_path.exists():
        return stats

    # Count known module directories
    known_modules = ["Chat", "Daily", "Build"]
    for module in known_modules:
        module_path = vault_path / module
        if module_path.exists():
            stats["modules"].append(module)

    # Count files and size (shallow)
    for item in vault_path.rglob("*"):
        if item.is_file() and not any(p.startswith(".") for p in item.parts):
            stats["total_files"] += 1
            try:
                stats["total_size"] += item.stat().st_size
            except OSError:
                pass

    return stats
