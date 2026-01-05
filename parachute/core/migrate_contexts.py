"""
Migrate Context Files to Parachute-Native Format.

Converts Claude-style prose context files to the structured Parachute-native format:
- Facts section (updateable)
- Current Focus section
- History section (append-only)

Run this script once to migrate existing context files.
"""

import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def extract_facts_from_prose(content: str) -> list[str]:
    """
    Extract fact-like statements from prose content.

    Looks for patterns like:
    - "X is Y"
    - "X works on Y"
    - "X uses Y"
    - Bullet points
    """
    facts = []

    # First, look for existing bullet points
    for line in content.split('\n'):
        line = line.strip()
        if re.match(r'^[-*]\s+', line):
            bullet = re.sub(r'^[-*]\s+', '', line)
            if bullet:
                facts.append(bullet)

    # Extract key facts from prose sections
    sections = {
        "work context": [],
        "personal context": [],
        "technical environment": [],
    }

    # Simple extraction patterns
    current_section = None
    for line in content.split('\n'):
        line = line.strip()

        # Detect section headers
        if line.startswith("**") and line.endswith("**"):
            header = line.strip("*").lower()
            if "work" in header:
                current_section = "work context"
            elif "personal" in header:
                current_section = "personal context"
            elif "technical" in header or "environment" in header:
                current_section = "technical environment"
            else:
                current_section = None

    return facts


def migrate_file_to_native_format(file_path: Path) -> bool:
    """
    Migrate a single context file to Parachute-native format.

    Returns True if migration was successful.
    """
    if not file_path.exists():
        return False

    content = file_path.read_text(encoding="utf-8")

    # Check if already migrated (has ## Facts or ## History)
    if re.search(r'^##\s+(Facts|History|Current Focus)', content, re.MULTILINE):
        print(f"  Already in native format: {file_path.name}")
        return True

    # Extract name from first heading
    name_match = re.match(r'^#\s+(.+)$', content, re.MULTILINE)
    name = name_match.group(1) if name_match else file_path.stem

    # Extract description
    desc_match = re.search(r'^#\s+.+\n+>\s*(.+)$', content, re.MULTILINE)
    description = desc_match.group(1) if desc_match else ""

    # Get the main prose content (everything after the ---)
    parts = content.split('---', 1)
    if len(parts) > 1:
        main_content = parts[1].strip()
    else:
        main_content = content

    # Extract any curator additions
    curator_additions = []
    curator_pattern = r'<!-- Added by curator on .+? -->\n(.+?)(?=<!-- Added by|$)'
    for match in re.finditer(curator_pattern, main_content, re.DOTALL):
        curator_additions.append(match.group(0).strip())

    # Remove curator additions from main content for processing
    main_content_clean = re.sub(curator_pattern, '', main_content, flags=re.DOTALL).strip()

    # Build new format
    new_parts = [f"# {name}"]

    if description:
        new_parts.append(f"\n> {description}")

    new_parts.append("\n\n---\n")

    # Facts section - extract key facts from prose
    new_parts.append("\n## Facts\n")
    new_parts.append("<!-- Key facts that can be updated by the curator -->\n")

    # Parse prose for factual statements (simple extraction)
    extracted_facts = extract_key_statements(main_content_clean)
    if extracted_facts:
        for fact in extracted_facts:
            new_parts.append(f"- {fact}\n")
    else:
        new_parts.append("<!-- No facts extracted yet -->\n")

    # Current Focus section
    new_parts.append("\n## Current Focus\n")
    new_parts.append("<!-- What's actively being worked on -->\n")
    focus_items = extract_current_focus(main_content_clean)
    if focus_items:
        for item in focus_items:
            new_parts.append(f"- {item}\n")

    # History section - move curator additions and original prose here
    new_parts.append("\n## History\n")
    new_parts.append("<!-- Append-only section for notable events and decisions -->\n")

    # Add original imported content as first history entry
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    new_parts.append(f"\n<!-- Migrated from Claude export format on {timestamp} -->\n")
    new_parts.append("*Original content preserved below for reference:*\n\n")

    # Preserve original prose in a collapsed section
    if main_content_clean:
        # Indent the original prose
        for line in main_content_clean.split('\n'):
            new_parts.append(f"> {line}\n")

    # Add curator additions as history entries
    for addition in curator_additions:
        new_parts.append(f"\n{addition}\n")

    # Write the migrated content
    new_content = "".join(new_parts)

    # Backup original
    backup_path = file_path.with_suffix('.md.bak')
    shutil.copy(file_path, backup_path)

    file_path.write_text(new_content, encoding="utf-8")
    print(f"  Migrated: {file_path.name} (backup: {backup_path.name})")
    return True


def extract_key_statements(content: str) -> list[str]:
    """Extract key factual statements from prose content."""
    facts = []

    # Look for patterns in the text
    patterns = [
        # "X is a Y" statements
        (r'([A-Z][^.]+) is (?:a |an |the )?([^.]+(?:founder|CEO|director|student|engineer|developer)[^.]*)', "role"),
        # "works on/with" statements
        (r'([A-Z][^.]+) (?:works on|is working on|developing|building) ([^.]+)', "project"),
        # "uses/prefers" statements
        (r'([A-Z][^.]+) (?:uses|prefers|runs) ([^.]+)', "tool"),
    ]

    # Extract common patterns
    sentences = re.split(r'[.!?]\s+', content)
    for sentence in sentences[:20]:  # Limit to avoid noise
        sentence = sentence.strip()
        if len(sentence) < 10 or len(sentence) > 200:
            continue

        # Look for key phrases
        if any(phrase in sentence.lower() for phrase in ['founder', 'ceo', 'director', 'based in', 'works at']):
            # Clean up the fact
            fact = sentence.strip()
            if fact and not fact.startswith('*') and not fact.startswith('>'):
                facts.append(fact)
                if len(facts) >= 5:
                    break

    return facts


def extract_current_focus(content: str) -> list[str]:
    """Extract current focus items from content."""
    focus = []

    # Look for "top of mind" or "current" sections
    top_of_mind_match = re.search(
        r'\*\*Top of mind\*\*\s*\n\n(.+?)(?=\n\n\*\*|\Z)',
        content,
        re.DOTALL | re.IGNORECASE
    )

    if top_of_mind_match:
        text = top_of_mind_match.group(1)
        sentences = re.split(r'[.]\s+', text)
        for sentence in sentences[:3]:
            sentence = sentence.strip()
            if len(sentence) > 20 and len(sentence) < 150:
                focus.append(sentence)

    # Look for "is developing/working on" phrases
    if not focus:
        developing_match = re.findall(
            r'is (?:developing|working on|building|creating) ([^.]+)',
            content,
            re.IGNORECASE
        )
        for match in developing_match[:3]:
            focus.append(match.strip())

    return focus


def migrate_all_contexts(vault_path: Path) -> dict:
    """
    Migrate all context files in a vault to Parachute-native format.

    Returns summary of migration.
    """
    contexts_dir = vault_path / "Chat" / "contexts"

    if not contexts_dir.exists():
        return {"error": "Contexts directory not found"}

    results = {
        "migrated": [],
        "skipped": [],
        "errors": [],
    }

    for file_path in sorted(contexts_dir.glob("*.md")):
        try:
            # Skip backup files
            if file_path.name.endswith('.bak'):
                continue

            success = migrate_file_to_native_format(file_path)
            if success:
                results["migrated"].append(file_path.name)
            else:
                results["skipped"].append(file_path.name)
        except Exception as e:
            results["errors"].append(f"{file_path.name}: {str(e)}")

    return results


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python -m parachute.core.migrate_contexts <vault_path>")
        print("Example: python -m parachute.core.migrate_contexts ~/Parachute")
        sys.exit(1)

    vault_path = Path(sys.argv[1]).expanduser()

    if not vault_path.exists():
        print(f"Error: Vault path doesn't exist: {vault_path}")
        sys.exit(1)

    print(f"Migrating context files in: {vault_path}")
    print()

    results = migrate_all_contexts(vault_path)

    print()
    print("Migration complete:")
    print(f"  Migrated: {len(results.get('migrated', []))}")
    print(f"  Skipped:  {len(results.get('skipped', []))}")
    print(f"  Errors:   {len(results.get('errors', []))}")

    if results.get("errors"):
        print("\nErrors:")
        for error in results["errors"]:
            print(f"  - {error}")
