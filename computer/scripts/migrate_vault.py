#!/usr/bin/env python3
"""
Vault Migration Script

Migrates Parachute sessions from one vault root to another. This is a one-time
operation that should be run when moving a vault to a new machine or path.

What it does:
1. Updates working_directory paths in the sessions database (absolute -> relative)
2. Copies transcript files (.jsonl) to the new location
3. Updates sessions-index.json files

Usage:
    python -m scripts.migrate_vault --from /Users/old/Parachute --to /Users/new/Parachute

    # Dry run (preview changes without applying):
    python -m scripts.migrate_vault --from /old --to /new --dry-run

    # Skip transcript copying (just update database):
    python -m scripts.migrate_vault --from /old --to /new --skip-transcripts
"""

import argparse
import json
import logging
import shutil
import sqlite3
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def decode_project_path(encoded_name: str) -> str:
    """Decode a project directory name to a path."""
    if encoded_name.startswith("-"):
        return "/" + encoded_name[1:].replace("-", "/")
    return encoded_name.replace("-", "/")


def encode_project_path(path: str) -> str:
    """Encode a path to a project directory name."""
    return path.replace("/", "-")


def migrate_database(
    db_path: Path,
    old_vault: str,
    new_vault: str,
    dry_run: bool = False,
) -> dict:
    """
    Migrate working_directory paths in the sessions database.

    Converts absolute paths under old_vault to relative paths,
    and clears vault_root since we now use relative paths.
    """
    results = {
        "sessions_updated": 0,
        "sessions_skipped": 0,
        "errors": [],
    }

    if not db_path.exists():
        logger.warning(f"Database not found: {db_path}")
        return results

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Get all sessions
    cursor.execute("SELECT id, working_directory, vault_root FROM sessions")
    sessions = cursor.fetchall()

    logger.info(f"Found {len(sessions)} sessions in database")

    for session_id, working_dir, vault_root in sessions:
        if not working_dir:
            results["sessions_skipped"] += 1
            continue

        wd_path = Path(working_dir)

        # Check if it's an absolute path under the old vault
        if wd_path.is_absolute():
            try:
                # Try to make it relative to old vault
                rel_path = wd_path.relative_to(old_vault)
                new_working_dir = str(rel_path) if str(rel_path) != "." else None

                logger.info(f"Session {session_id[:8]}: {working_dir} -> {new_working_dir or '(vault root)'}")

                if not dry_run:
                    cursor.execute(
                        "UPDATE sessions SET working_directory = ?, vault_root = NULL WHERE id = ?",
                        (new_working_dir, session_id)
                    )

                results["sessions_updated"] += 1

            except ValueError:
                # Path is not under old vault - check if under new vault
                try:
                    rel_path = wd_path.relative_to(new_vault)
                    new_working_dir = str(rel_path) if str(rel_path) != "." else None

                    logger.info(f"Session {session_id[:8]}: already under new vault, converting to relative: {new_working_dir or '(vault root)'}")

                    if not dry_run:
                        cursor.execute(
                            "UPDATE sessions SET working_directory = ?, vault_root = NULL WHERE id = ?",
                            (new_working_dir, session_id)
                        )

                    results["sessions_updated"] += 1

                except ValueError:
                    # External project - leave as absolute but warn
                    logger.warning(f"Session {session_id[:8]}: external path {working_dir}, keeping absolute")
                    results["sessions_skipped"] += 1
        else:
            # Already relative
            logger.info(f"Session {session_id[:8]}: already relative ({working_dir})")
            results["sessions_skipped"] += 1

    if not dry_run:
        conn.commit()
        logger.info(f"Database changes committed")
    else:
        logger.info("Dry run - no changes committed")

    conn.close()
    return results


def migrate_transcripts(
    old_vault: Path,
    new_vault: Path,
    dry_run: bool = False,
    cleanup: bool = False,
) -> dict:
    """
    Copy transcript files from old vault's .claude/projects to new location.

    Also searches in ~/.claude/projects for sessions that were created there.
    If cleanup=True, removes old directories after successful copy.
    """
    results = {
        "files_copied": 0,
        "files_skipped": 0,
        "directories_processed": 0,
        "directories_cleaned": 0,
        "errors": [],
    }

    # Track directories to clean up
    dirs_to_cleanup = []

    # Locations to search for transcripts
    search_locations = [
        (old_vault / ".claude" / "projects", "old vault"),
        (Path.home() / ".claude" / "projects", "home"),
    ]

    new_claude_projects = new_vault / ".claude" / "projects"

    for search_path, location_name in search_locations:
        if not search_path.exists():
            logger.info(f"No .claude/projects in {location_name}: {search_path}")
            continue

        logger.info(f"Scanning {location_name}: {search_path}")

        for project_dir in search_path.iterdir():
            if not project_dir.is_dir():
                continue

            decoded_path = decode_project_path(project_dir.name)
            results["directories_processed"] += 1

            # Check if this directory path is under the old vault
            try:
                rel_path = Path(decoded_path).relative_to(old_vault)
            except ValueError:
                # Not under old vault - skip
                continue

            # Compute new directory path
            new_abs_path = new_vault / rel_path
            new_encoded = encode_project_path(str(new_abs_path))
            new_project_dir = new_claude_projects / new_encoded

            # Copy all JSONL files
            for jsonl_file in project_dir.glob("*.jsonl"):
                new_file = new_project_dir / jsonl_file.name

                if new_file.exists():
                    logger.debug(f"  Already exists: {new_file.name}")
                    results["files_skipped"] += 1
                    continue

                logger.info(f"  Copy: {jsonl_file.name}")
                logger.info(f"    From: {project_dir}")
                logger.info(f"    To:   {new_project_dir}")

                if not dry_run:
                    try:
                        new_project_dir.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(jsonl_file, new_file)
                        results["files_copied"] += 1
                    except Exception as e:
                        logger.error(f"  Failed to copy: {e}")
                        results["errors"].append(str(e))
                else:
                    results["files_copied"] += 1

            # Also copy sessions-index.json if present
            sessions_index = project_dir / "sessions-index.json"
            if sessions_index.exists():
                new_index = new_project_dir / "sessions-index.json"
                if not new_index.exists():
                    logger.info(f"  Copy sessions-index.json")
                    if not dry_run:
                        try:
                            new_project_dir.mkdir(parents=True, exist_ok=True)
                            # Update paths in sessions-index.json
                            with open(sessions_index) as f:
                                index_data = json.load(f)

                            # Update paths
                            if "originalPath" in index_data:
                                old_orig = index_data["originalPath"]
                                try:
                                    rel = Path(old_orig).relative_to(old_vault)
                                    index_data["originalPath"] = str(new_vault / rel)
                                except ValueError:
                                    pass

                            for entry in index_data.get("entries", []):
                                if "fullPath" in entry:
                                    old_full = entry["fullPath"]
                                    try:
                                        # Replace old vault with new vault in path
                                        entry["fullPath"] = old_full.replace(str(old_vault), str(new_vault))
                                    except Exception:
                                        pass
                                if "projectPath" in entry:
                                    old_proj = entry["projectPath"]
                                    try:
                                        rel = Path(old_proj).relative_to(old_vault)
                                        entry["projectPath"] = str(new_vault / rel)
                                    except ValueError:
                                        pass

                            with open(new_index, "w") as f:
                                json.dump(index_data, f, indent=2)
                        except Exception as e:
                            logger.error(f"  Failed to update sessions-index.json: {e}")
                            results["errors"].append(str(e))

            # Track this directory for cleanup
            if cleanup and project_dir != new_project_dir:
                dirs_to_cleanup.append(project_dir)

    # Cleanup old directories if requested
    if cleanup and dirs_to_cleanup:
        logger.info(f"Cleaning up {len(dirs_to_cleanup)} old directories...")
        for old_dir in dirs_to_cleanup:
            if dry_run:
                logger.info(f"  Would remove: {old_dir}")
                results["directories_cleaned"] += 1
            else:
                try:
                    shutil.rmtree(old_dir)
                    logger.info(f"  Removed: {old_dir}")
                    results["directories_cleaned"] += 1
                except Exception as e:
                    logger.error(f"  Failed to remove {old_dir}: {e}")
                    results["errors"].append(str(e))

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Migrate Parachute vault from one path to another",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--from", dest="from_vault", required=True,
        help="Old vault path (e.g., /Users/old/Parachute)"
    )
    parser.add_argument(
        "--to", dest="to_vault", required=True,
        help="New vault path (e.g., /Users/new/Parachute)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Preview changes without applying them"
    )
    parser.add_argument(
        "--cleanup", action="store_true",
        help="Remove old transcript directories after copying (use with caution)"
    )
    parser.add_argument(
        "--skip-transcripts", action="store_true",
        help="Skip copying transcript files (only update database)"
    )
    parser.add_argument(
        "--db-path",
        help="Path to sessions.db (default: {to_vault}/Chat/sessions.db)"
    )

    args = parser.parse_args()

    old_vault = Path(args.from_vault).resolve()
    new_vault = Path(args.to_vault).resolve()

    if args.dry_run:
        logger.info("=== DRY RUN MODE - No changes will be made ===\n")

    logger.info(f"Migrating vault:")
    logger.info(f"  From: {old_vault}")
    logger.info(f"  To:   {new_vault}")
    logger.info("")

    # Determine database path
    db_path = Path(args.db_path) if args.db_path else new_vault / "Chat" / "sessions.db"

    # Step 1: Migrate database
    logger.info("=== Step 1: Migrating Database ===")
    db_results = migrate_database(db_path, str(old_vault), str(new_vault), args.dry_run)
    logger.info(f"Database: {db_results['sessions_updated']} updated, {db_results['sessions_skipped']} skipped")
    logger.info("")

    # Step 2: Migrate transcripts
    if not args.skip_transcripts:
        logger.info("=== Step 2: Migrating Transcript Files ===")
        if args.cleanup:
            logger.info("(Cleanup mode: old directories will be removed)")
        transcript_results = migrate_transcripts(old_vault, new_vault, args.dry_run, args.cleanup)
        logger.info(f"Transcripts: {transcript_results['files_copied']} copied, {transcript_results['files_skipped']} skipped")
        if args.cleanup:
            logger.info(f"Cleanup: {transcript_results['directories_cleaned']} directories removed")
        if transcript_results["errors"]:
            logger.warning(f"Errors: {len(transcript_results['errors'])}")
    else:
        logger.info("=== Step 2: Skipping Transcript Migration ===")
        transcript_results = {}

    logger.info("")
    logger.info("=== Migration Complete ===")

    if args.dry_run:
        logger.info("This was a dry run. Run without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
