#!/usr/bin/env python3
"""
Test script to verify we can synthesize SDK JSONL files from Claude exports.

This script:
1. Reads a conversation from a Claude export
2. Converts it to SDK JSONL format
3. Writes it to ~/.claude/projects/{vault-path}/
4. Attempts to load it via the session manager to verify it works
"""

import json
import os
import uuid
from datetime import datetime
from pathlib import Path


def load_claude_export(export_path: str) -> list[dict]:
    """Load conversations from a Claude export file."""
    with open(export_path, 'r') as f:
        return json.load(f)


def convert_conversation_to_sdk_jsonl(
    conversation: dict,
    vault_path: str = "/Users/unforced/Parachute",
    new_session_id: str | None = None
) -> tuple[str, list[dict]]:
    """
    Convert a Claude export conversation to SDK JSONL format.

    Returns:
        tuple: (session_id, list of JSONL events)
    """
    session_id = new_session_id or str(uuid.uuid4())
    events = []

    # Add initial queue-operation event
    events.append({
        "type": "queue-operation",
        "operation": "dequeue",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "sessionId": session_id
    })

    messages = conversation.get('chat_messages', [])
    prev_uuid = None

    for msg in messages:
        msg_uuid = str(uuid.uuid4())  # Generate new UUID for SDK format
        sender = msg.get('sender', 'human')
        text = msg.get('text', '')
        created_at = msg.get('created_at', datetime.utcnow().isoformat() + "Z")

        if sender == 'human':
            event = {
                "parentUuid": prev_uuid,
                "isSidechain": False,
                "userType": "external",
                "cwd": vault_path,
                "sessionId": session_id,
                "version": "2.0.60",
                "gitBranch": "",
                "type": "user",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": text}]
                },
                "uuid": msg_uuid,
                "timestamp": created_at
            }
        else:  # assistant
            event = {
                "parentUuid": prev_uuid,
                "isSidechain": False,
                "userType": "external",
                "cwd": vault_path,
                "sessionId": session_id,
                "version": "2.0.60",
                "gitBranch": "",
                "message": {
                    "model": "claude-3-5-sonnet-20241022",  # Original model unknown
                    "id": f"msg_{uuid.uuid4().hex[:24]}",
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {
                        "input_tokens": 0,
                        "output_tokens": 0
                    }
                },
                "requestId": f"req_{uuid.uuid4().hex[:24]}",
                "type": "assistant",
                "uuid": msg_uuid,
                "timestamp": created_at
            }

        events.append(event)
        prev_uuid = msg_uuid

    return session_id, events


def write_sdk_jsonl(session_id: str, events: list[dict], vault_path: str):
    """Write events to SDK JSONL file location."""
    # Encode vault path for directory name
    encoded_path = vault_path.replace('/', '-')
    if encoded_path.startswith('-'):
        encoded_path = encoded_path  # Keep leading dash

    sdk_dir = Path.home() / ".claude" / "projects" / encoded_path
    sdk_dir.mkdir(parents=True, exist_ok=True)

    jsonl_path = sdk_dir / f"{session_id}.jsonl"

    with open(jsonl_path, 'w') as f:
        for event in events:
            f.write(json.dumps(event) + '\n')

    return jsonl_path


def test_load_synthesized_session(session_id: str, vault_path: str):
    """Test loading the synthesized session via session manager."""
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))

    from parachute.core.session_manager import SessionManager

    manager = SessionManager(vault_path)

    # Try to load messages from the session
    messages = manager.get_session_messages(session_id)

    return messages


def main():
    import argparse

    parser = argparse.ArgumentParser(description='Test SDK JSONL synthesis from Claude exports')
    parser.add_argument('--export', default='/Users/unforced/Parachute/imports/data-2025-12-26-20-56-04-batch-0000/conversations.json',
                        help='Path to Claude export conversations.json')
    parser.add_argument('--vault', default='/Users/unforced/Parachute',
                        help='Vault path')
    parser.add_argument('--index', type=int, default=0,
                        help='Index of conversation to convert (default: 0)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print JSONL without writing')
    parser.add_argument('--list', action='store_true',
                        help='List available conversations')

    args = parser.parse_args()

    # Load export
    print(f"Loading Claude export from: {args.export}")
    conversations = load_claude_export(args.export)
    print(f"Found {len(conversations)} conversations")

    if args.list:
        print("\nConversations:")
        for i, conv in enumerate(conversations[:20]):
            name = conv.get('name', 'Untitled')[:50]
            msg_count = len(conv.get('chat_messages', []))
            print(f"  [{i}] {name} ({msg_count} messages)")
        if len(conversations) > 20:
            print(f"  ... and {len(conversations) - 20} more")
        return

    # Select conversation
    conv = conversations[args.index]
    print(f"\nConverting: {conv.get('name', 'Untitled')}")
    print(f"  Original UUID: {conv.get('uuid')}")
    print(f"  Messages: {len(conv.get('chat_messages', []))}")

    # Convert to SDK JSONL
    session_id, events = convert_conversation_to_sdk_jsonl(conv, args.vault)
    print(f"  New Session ID: {session_id}")
    print(f"  Generated {len(events)} JSONL events")

    if args.dry_run:
        print("\n--- JSONL Preview (first 3 events) ---")
        for event in events[:3]:
            print(json.dumps(event, indent=2))
        print("...")
        return

    # Write to SDK location
    jsonl_path = write_sdk_jsonl(session_id, events, args.vault)
    print(f"\nWritten to: {jsonl_path}")

    # Test loading
    print("\nTesting load via SessionManager...")
    try:
        messages = test_load_synthesized_session(session_id, args.vault)
        print(f"✓ Successfully loaded {len(messages)} messages!")

        # Show first message
        if messages:
            first = messages[0]
            print(f"\nFirst message preview:")
            print(f"  Role: {first.get('role')}")
            text = first.get('content', '')[:100]
            print(f"  Content: {text}...")
    except Exception as e:
        print(f"✗ Failed to load: {e}")
        import traceback
        traceback.print_exc()

    print(f"\n--- Summary ---")
    print(f"Session ID: {session_id}")
    print(f"JSONL Path: {jsonl_path}")
    print(f"\nTo test in Parachute Chat:")
    print(f"  1. Add session to SQLite database")
    print(f"  2. Open in Chat app")
    print(f"  3. Try continuing the conversation")


if __name__ == '__main__':
    main()
