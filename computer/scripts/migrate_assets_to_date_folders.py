#!/usr/bin/env python3
"""
Migrate assets from month-based to date-based folder structure.

Handles multiple file naming patterns:
1. New standard: YYYY-MM-DD_HHMMSS_type.ext -> HHMMSS_type.ext
2. Old format:   YYYY-MM-DD_HH-MM.ext -> HH-MM.ext
3. Agent output: YYYY-MM-DD-description.ext -> description.ext

Also updates references in:
- Daily/journals/*.md
- Daily/reflection/*.md
- Daily/lessons/*.md
- Daily/.agents/*.md (templates)
"""

import re
import shutil
from pathlib import Path


def migrate_vault(vault_path: Path, dry_run: bool = True) -> None:
    """Migrate a vault's assets to date-based folders."""

    # Process both Daily and Chat modules
    for module in ["Daily", "Chat"]:
        assets_dir = vault_path / module / "assets"
        if not assets_dir.exists():
            print(f"[{module}] No assets directory found, skipping")
            continue

        print(f"\n=== Migrating {module}/assets ===")
        migrate_assets_directory(assets_dir, dry_run)

    # Update references in all relevant directories
    daily_dir = vault_path / "Daily"

    for subdir in ["journals", "reflection", "lessons"]:
        target_dir = daily_dir / subdir
        if target_dir.exists():
            print(f"\n=== Updating {subdir} references ===")
            update_markdown_references(target_dir, dry_run)

    # Update agent templates
    agents_dir = daily_dir / ".agents"
    if agents_dir.exists():
        print(f"\n=== Updating agent templates ===")
        update_agent_templates(agents_dir, dry_run)


def migrate_assets_directory(assets_dir: Path, dry_run: bool) -> None:
    """Move assets from month folders to date folders."""

    # Pattern for month folders: YYYY-MM
    month_pattern = re.compile(r"^\d{4}-\d{2}$")

    # File patterns to match (all start with YYYY-MM-DD)
    file_patterns = [
        # Pattern 1: YYYY-MM-DD_HHMMSS_type.ext (new standard)
        (re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{6}_\w+\.\w+)$"),
         lambda m: (m.group(1), m.group(2))),

        # Pattern 2: YYYY-MM-DD_HH-MM.ext (old format with dashes in time)
        (re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}\.\w+)$"),
         lambda m: (m.group(1), m.group(2))),

        # Pattern 3: YYYY-MM-DD-description.ext (agent outputs like reflection-image.png)
        (re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+\.\w+)$"),
         lambda m: (m.group(1), m.group(2))),
    ]

    moved_count = 0

    for item in assets_dir.iterdir():
        if not item.is_dir():
            continue

        # Check if this is a month folder (YYYY-MM)
        if not month_pattern.match(item.name):
            continue

        print(f"\nProcessing month folder: {item.name}")

        for asset_file in item.iterdir():
            if not asset_file.is_file():
                continue

            # Try each pattern
            matched = False
            for pattern, extractor in file_patterns:
                match = pattern.match(asset_file.name)
                if match:
                    date_str, new_filename = extractor(match)

                    # Create new date folder
                    new_folder = assets_dir / date_str
                    new_path = new_folder / new_filename

                    print(f"  {asset_file.name} -> {date_str}/{new_filename}")

                    if not dry_run:
                        new_folder.mkdir(exist_ok=True)
                        shutil.move(str(asset_file), str(new_path))

                    moved_count += 1
                    matched = True
                    break

            if not matched:
                print(f"  Skipping non-matching file: {asset_file.name}")

        # Remove empty month folder after migration
        if not dry_run:
            try:
                item.rmdir()
                print(f"  Removed empty folder: {item.name}")
            except OSError:
                print(f"  Folder not empty, keeping: {item.name}")

    print(f"\n{'Would move' if dry_run else 'Moved'} {moved_count} files")


def update_markdown_references(target_dir: Path, dry_run: bool) -> None:
    """Update asset path references in markdown files."""

    # Patterns to match old-style asset references
    patterns = [
        # Pattern 1: assets/YYYY-MM/YYYY-MM-DD_... (underscore separator)
        (re.compile(r"assets/(\d{4}-\d{2})/(\d{4}-\d{2}-\d{2})_([^\s\n\"'\)]+)"),
         lambda m: f"assets/{m.group(2)}/{m.group(3)}"),

        # Pattern 2: assets/YYYY-MM/YYYY-MM-DD-... (dash separator for agent outputs)
        (re.compile(r"assets/(\d{4}-\d{2})/(\d{4}-\d{2}-\d{2})-([^\s\n\"'\)]+)"),
         lambda m: f"assets/{m.group(2)}/{m.group(3)}"),

        # Pattern 3: ../assets/YYYY-MM/YYYY-MM-DD_... (relative path with underscore)
        (re.compile(r"\.\./assets/(\d{4}-\d{2})/(\d{4}-\d{2}-\d{2})_([^\s\n\"'\)]+)"),
         lambda m: f"../assets/{m.group(2)}/{m.group(3)}"),

        # Pattern 4: ../assets/YYYY-MM/YYYY-MM-DD-... (relative path with dash)
        (re.compile(r"\.\./assets/(\d{4}-\d{2})/(\d{4}-\d{2}-\d{2})-([^\s\n\"'\)]+)"),
         lambda m: f"../assets/{m.group(2)}/{m.group(3)}"),
    ]

    updated_files = 0
    updated_refs = 0

    for md_file in target_dir.glob("*.md"):
        try:
            content = md_file.read_text(encoding="utf-8")
        except Exception as e:
            print(f"  Error reading {md_file.name}: {e}")
            continue

        new_content = content
        file_refs = 0

        for pattern, replacer in patterns:
            # Find all matches and replace
            for match in pattern.finditer(content):
                old_ref = match.group(0)
                new_ref = replacer(match)

                if old_ref in new_content and old_ref != new_ref:
                    new_content = new_content.replace(old_ref, new_ref)
                    file_refs += 1
                    print(f"  {md_file.name}: {old_ref} -> {new_ref}")

        if file_refs > 0:
            if not dry_run:
                md_file.write_text(new_content, encoding="utf-8")
            updated_files += 1
            updated_refs += file_refs

    print(f"\n{'Would update' if dry_run else 'Updated'} {updated_refs} references in {updated_files} files")


def update_agent_templates(agents_dir: Path, dry_run: bool) -> None:
    """Update agent template files to use new path format."""

    # These templates use placeholder patterns like {year-month} and {date}
    # We need to update them to use {date} folder structure

    old_patterns = [
        # ../assets/{year-month}/{date}-... -> ../assets/{date}/...
        (r"\.\./assets/\{year-month\}/\{date\}-", "../assets/{date}/"),
        # assets/{year-month}/{date}-... -> assets/{date}/...
        (r"assets/\{year-month\}/\{date\}-", "assets/{date}/"),
    ]

    updated_files = 0

    for agent_file in agents_dir.glob("*.md"):
        try:
            content = agent_file.read_text(encoding="utf-8")
        except Exception as e:
            print(f"  Error reading {agent_file.name}: {e}")
            continue

        new_content = content
        changed = False

        for old_pattern, new_pattern in old_patterns:
            if re.search(old_pattern, new_content):
                new_content = re.sub(old_pattern, new_pattern, new_content)
                changed = True
                print(f"  {agent_file.name}: Updated template paths")

        if changed:
            if not dry_run:
                agent_file.write_text(new_content, encoding="utf-8")
            updated_files += 1

    print(f"\n{'Would update' if dry_run else 'Updated'} {updated_files} agent templates")


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Migrate vault assets from month-based to date-based folders"
    )
    parser.add_argument(
        "--vault",
        type=Path,
        default=Path.home(),
        help="Path to vault (default: ~ i.e. home directory)"
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually perform the migration (default: dry run)"
    )

    args = parser.parse_args()

    if not args.vault.exists():
        print(f"Vault not found: {args.vault}")
        return 1

    dry_run = not args.execute

    if dry_run:
        print("=== DRY RUN MODE ===")
        print("Use --execute to actually perform the migration\n")
    else:
        print("=== EXECUTING MIGRATION ===\n")

    migrate_vault(args.vault, dry_run=dry_run)

    if dry_run:
        print("\n=== DRY RUN COMPLETE ===")
        print("Run with --execute to apply changes")
    else:
        print("\n=== MIGRATION COMPLETE ===")

    return 0


if __name__ == "__main__":
    exit(main())
