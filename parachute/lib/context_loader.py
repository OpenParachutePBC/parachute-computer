"""
Context/knowledge file loader for agents.

Loads context files from the vault and formats them for inclusion in prompts.
"""

import logging
from pathlib import Path
from typing import Any, Optional

import frontmatter

logger = logging.getLogger(__name__)

# Rough estimate: 4 chars per token
CHARS_PER_TOKEN = 4


async def load_agent_context(
    context_config: dict[str, Any],
    vault_path: Path,
    options: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """
    Load context files based on agent context configuration.

    Args:
        context_config: Agent's context configuration with 'include', 'exclude', etc.
        vault_path: Path to the vault
        options: Additional options like max_tokens

    Returns:
        Dict with 'content', 'files', 'totalTokens', 'truncated'
    """
    options = options or {}
    max_tokens = context_config.get("max_tokens", options.get("max_tokens", 50000))
    max_chars = max_tokens * CHARS_PER_TOKEN

    include_patterns = context_config.get("include", [])
    exclude_patterns = context_config.get("exclude", [])
    knowledge_file = context_config.get("knowledge_file")

    # Collect files to load
    files_to_load: list[Path] = []

    # Handle knowledge_file (single file path)
    if knowledge_file:
        kf_path = vault_path / knowledge_file
        if kf_path.exists():
            files_to_load.append(kf_path)

    # Handle include patterns
    for pattern in include_patterns:
        if "*" in pattern:
            # Glob pattern
            for match in vault_path.glob(pattern):
                if match.is_file() and not _matches_exclude(match, exclude_patterns, vault_path):
                    files_to_load.append(match)
        else:
            # Direct path
            file_path = vault_path / pattern
            if file_path.exists() and file_path.is_file():
                files_to_load.append(file_path)

    # Load content from files
    loaded_files: list[str] = []
    content_parts: list[str] = []
    total_chars = 0
    truncated = False

    for file_path in files_to_load:
        if total_chars >= max_chars:
            truncated = True
            break

        try:
            relative_path = str(file_path.relative_to(vault_path))
            file_content = await _load_file_content(file_path)

            if file_content:
                remaining = max_chars - total_chars
                if len(file_content) > remaining:
                    file_content = file_content[:remaining] + "\n[...truncated]"
                    truncated = True

                content_parts.append(f"## {relative_path}\n\n{file_content}")
                loaded_files.append(relative_path)
                total_chars += len(file_content)

        except Exception as e:
            logger.warning(f"Error loading context file {file_path}: {e}")

    combined_content = "\n\n---\n\n".join(content_parts)
    estimated_tokens = total_chars // CHARS_PER_TOKEN

    return {
        "content": combined_content,
        "files": loaded_files,
        "totalTokens": estimated_tokens,
        "truncated": truncated,
    }


def _matches_exclude(file_path: Path, patterns: list[str], vault_path: Path) -> bool:
    """Check if a file matches any exclude pattern."""
    from parachute.lib.vault_utils import matches_patterns

    relative = str(file_path.relative_to(vault_path))
    return matches_patterns(relative, patterns)


async def _load_file_content(file_path: Path) -> Optional[str]:
    """Load content from a file, parsing frontmatter if markdown."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Parse frontmatter for markdown files
        if file_path.suffix == ".md":
            post = frontmatter.loads(content)
            return post.content.strip()

        return content.strip()
    except Exception as e:
        logger.debug(f"Failed to read {file_path}: {e}")
        return None


def format_context_for_prompt(context_result: dict[str, Any]) -> str:
    """
    Format loaded context for inclusion in a system prompt.

    Args:
        context_result: Result from load_agent_context

    Returns:
        Formatted string for system prompt
    """
    if not context_result.get("content"):
        return ""

    header = f"\n\n## Project Knowledge\n"
    header += f"The following context has been loaded for your reference "
    header += f"({len(context_result['files'])} files, ~{context_result['totalTokens']} tokens):\n\n"

    footer = ""
    if context_result.get("truncated"):
        footer = "\n\n*[Context truncated due to token limit]*"

    return header + context_result["content"] + footer
