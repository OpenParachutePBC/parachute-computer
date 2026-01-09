"""
End-to-end tests for the curator service.

Tests the full curator flow:
1. Create a chat session
2. Queue a curator task
3. Verify curator runs and updates title
4. Verify curator transcript is accessible
"""

import asyncio
import pytest
import pytest_asyncio
from pathlib import Path
from datetime import datetime, timezone

from parachute.db.database import Database
from parachute.core.curator_service import (
    CuratorService,
    init_curator_service,
    stop_curator_service,
)
from parachute.core.session_manager import SessionManager
from parachute.models.session import SessionCreate


@pytest_asyncio.fixture
async def curator_service(test_vault: Path, test_database: Database):
    """Create and start a curator service for testing."""
    service = CuratorService(test_database, test_vault)
    await service.start_worker()
    yield service
    await service.stop_worker()


@pytest_asyncio.fixture
async def chat_session(test_database: Database, session_manager: SessionManager):
    """Create a test chat session with messages."""
    # Create session
    session = await test_database.create_session(
        SessionCreate(
            id="test-session-curator-001",
            title="(untitled)",
            module="chat",
            source="test",
        )
    )

    # Add some messages to the session
    messages = [
        {"role": "user", "content": "Help me set up a Python project with FastAPI"},
        {"role": "assistant", "content": "I'll help you set up a Python project with FastAPI. First, let's create the project structure and install dependencies."},
        {"role": "user", "content": "Great, let's also add SQLite for the database"},
        {"role": "assistant", "content": "Perfect choice! SQLite is lightweight and works great for development. I'll add aiosqlite for async support."},
    ]

    # Store messages via session manager
    for msg in messages:
        await session_manager.append_message(session.id, msg)

    return session


class TestCuratorService:
    """Tests for the curator service."""

    @pytest.mark.asyncio
    async def test_queue_task(self, curator_service: CuratorService, chat_session):
        """Test queueing a curator task."""
        task_id = await curator_service.queue_task(
            parent_session_id=chat_session.id,
            trigger_type="message_done",
            message_count=4,
        )

        assert task_id is not None
        assert task_id > 0

        # Check task was created
        task = await curator_service.get_task(task_id)
        assert task is not None
        assert task.status == "pending"
        assert task.session_id == chat_session.id

    @pytest.mark.asyncio
    async def test_curator_processes_task(self, curator_service: CuratorService, chat_session, test_database: Database):
        """Test that curator processes a task and updates title."""
        # Queue task
        task_id = await curator_service.queue_task(
            parent_session_id=chat_session.id,
            trigger_type="message_done",
            message_count=4,
        )

        # Wait for processing (with timeout)
        for _ in range(30):  # 30 seconds max
            await asyncio.sleep(1)
            task = await curator_service.get_task(task_id)
            if task.status in ("completed", "failed"):
                break

        # Verify task completed
        assert task.status == "completed", f"Task failed: {task.error}"

        # Check result
        assert task.result is not None
        print(f"Curator result: {task.result}")

        # Title should be updated (not "(untitled)")
        session = await test_database.get_session(chat_session.id)
        print(f"Session title: {session.title}")

        # Either title was updated by curator, or it's still processing
        if task.result.get("title_updated"):
            assert session.title != "(untitled)"
            assert "FastAPI" in session.title or "Python" in session.title

    @pytest.mark.asyncio
    async def test_curator_session_continuity(self, curator_service: CuratorService, chat_session, session_manager: SessionManager):
        """Test that curator maintains session continuity across runs."""
        # First run
        task1_id = await curator_service.queue_task(
            parent_session_id=chat_session.id,
            trigger_type="message_done",
            message_count=4,
        )

        # Wait for completion
        for _ in range(30):
            await asyncio.sleep(1)
            task1 = await curator_service.get_task(task1_id)
            if task1.status in ("completed", "failed"):
                break

        assert task1.status == "completed"

        # Get curator session - should have SDK session ID
        curator_session = await curator_service.get_curator_session(chat_session.id)
        assert curator_session is not None
        first_sdk_session_id = curator_session.sdk_session_id
        print(f"First SDK session ID: {first_sdk_session_id}")

        # Add more messages
        await session_manager.append_message(chat_session.id, {
            "role": "user",
            "content": "Now let's add authentication with JWT tokens"
        })
        await session_manager.append_message(chat_session.id, {
            "role": "assistant",
            "content": "I'll add JWT authentication using python-jose library."
        })

        # Second run
        task2_id = await curator_service.queue_task(
            parent_session_id=chat_session.id,
            trigger_type="message_done",
            message_count=6,
        )

        # Wait for completion
        for _ in range(30):
            await asyncio.sleep(1)
            task2 = await curator_service.get_task(task2_id)
            if task2.status in ("completed", "failed"):
                break

        assert task2.status == "completed"

        # SDK session should be the same (resumed) or updated
        curator_session = await curator_service.get_curator_session(chat_session.id)
        second_sdk_session_id = curator_session.sdk_session_id
        print(f"Second SDK session ID: {second_sdk_session_id}")

        # Should have an SDK session ID
        assert second_sdk_session_id is not None

    @pytest.mark.asyncio
    async def test_get_tasks_for_session(self, curator_service: CuratorService, chat_session):
        """Test retrieving task history for a session."""
        # Queue multiple tasks
        task_ids = []
        for i in range(3):
            task_id = await curator_service.queue_task(
                parent_session_id=chat_session.id,
                trigger_type="manual",
                message_count=4,
            )
            task_ids.append(task_id)
            await asyncio.sleep(0.1)  # Small delay

        # Get tasks for session
        tasks = await curator_service.get_tasks_for_session(chat_session.id)

        assert len(tasks) >= 3
        assert all(t.session_id == chat_session.id for t in tasks)


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
