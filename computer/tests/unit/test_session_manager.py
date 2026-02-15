"""
Unit tests for session manager.
"""

import pytest
from datetime import datetime

from parachute.models.session import SessionCreate, SessionSource


@pytest.mark.asyncio
async def test_create_session(session_manager, test_database):
    """Test creating a new session."""
    session_data = SessionCreate(
        id="test-session-001",
        title="Test Session",
        module="chat",
        source=SessionSource.PARACHUTE,
    )

    session = await test_database.create_session(session_data)

    assert session.id == "test-session-001"
    assert session.title == "Test Session"
    assert session.module == "chat"
    assert session.source == SessionSource.PARACHUTE
    assert session.message_count == 0
    assert session.archived is False


@pytest.mark.asyncio
async def test_get_session(session_manager, test_database):
    """Test getting a session by ID."""
    # Create a session first
    session_data = SessionCreate(
        id="test-session-002",
        title="Get Test",
        module="chat",
    )
    await test_database.create_session(session_data)

    # Get it back
    session = await test_database.get_session("test-session-002")

    assert session is not None
    assert session.id == "test-session-002"
    assert session.title == "Get Test"


@pytest.mark.asyncio
async def test_get_nonexistent_session(session_manager, test_database):
    """Test getting a session that doesn't exist."""
    session = await test_database.get_session("nonexistent-session")
    assert session is None


@pytest.mark.asyncio
async def test_list_sessions(session_manager, test_database):
    """Test listing sessions."""
    # Create multiple sessions
    for i in range(5):
        await test_database.create_session(
            SessionCreate(
                id=f"list-test-session-{i}",
                title=f"List Test {i}",
                module="chat",
            )
        )

    sessions = await test_database.list_sessions()

    assert len(sessions) >= 5


@pytest.mark.asyncio
async def test_list_sessions_with_module_filter(session_manager, test_database):
    """Test filtering sessions by module."""
    # Create sessions in different modules
    await test_database.create_session(
        SessionCreate(id="chat-session-1", module="chat")
    )
    await test_database.create_session(
        SessionCreate(id="daily-session-1", module="daily")
    )

    chat_sessions = await test_database.list_sessions(module="chat")
    daily_sessions = await test_database.list_sessions(module="daily")

    # Check that filtering works
    chat_ids = [s.id for s in chat_sessions]
    daily_ids = [s.id for s in daily_sessions]

    assert "chat-session-1" in chat_ids
    assert "daily-session-1" not in chat_ids
    assert "daily-session-1" in daily_ids


@pytest.mark.asyncio
async def test_archive_session(session_manager, test_database):
    """Test archiving a session."""
    await test_database.create_session(
        SessionCreate(id="archive-test-session", module="chat")
    )

    session = await test_database.archive_session("archive-test-session")

    assert session is not None
    assert session.archived is True


@pytest.mark.asyncio
async def test_unarchive_session(session_manager, test_database):
    """Test unarchiving a session."""
    await test_database.create_session(
        SessionCreate(id="unarchive-test-session", module="chat")
    )
    await test_database.archive_session("unarchive-test-session")

    session = await test_database.unarchive_session("unarchive-test-session")

    assert session is not None
    assert session.archived is False


@pytest.mark.asyncio
async def test_delete_session(session_manager, test_database):
    """Test deleting a session."""
    await test_database.create_session(
        SessionCreate(id="delete-test-session", module="chat")
    )

    success = await test_database.delete_session("delete-test-session")
    assert success is True

    # Verify it's gone
    session = await test_database.get_session("delete-test-session")
    assert session is None


@pytest.mark.asyncio
async def test_increment_message_count(session_manager, test_database):
    """Test incrementing message count."""
    await test_database.create_session(
        SessionCreate(id="count-test-session", module="chat")
    )

    await test_database.increment_message_count("count-test-session", 2)
    session = await test_database.get_session("count-test-session")

    assert session.message_count == 2

    await test_database.increment_message_count("count-test-session", 2)
    session = await test_database.get_session("count-test-session")

    assert session.message_count == 4


@pytest.mark.asyncio
async def test_session_with_working_directory(session_manager, test_database):
    """Test session with working directory."""
    await test_database.create_session(
        SessionCreate(
            id="cwd-test-session",
            module="chat",
            working_directory="/some/project/path",
        )
    )

    session = await test_database.get_session("cwd-test-session")

    assert session.working_directory == "/some/project/path"


@pytest.mark.asyncio
async def test_session_with_metadata(session_manager, test_database):
    """Test session with custom metadata."""
    await test_database.create_session(
        SessionCreate(
            id="meta-test-session",
            module="chat",
            metadata={"custom_field": "custom_value", "number": 42},
        )
    )

    session = await test_database.get_session("meta-test-session")

    assert session.metadata is not None
    assert session.metadata["custom_field"] == "custom_value"
    assert session.metadata["number"] == 42


# ── resolve_working_directory tests ──


def test_resolve_working_directory_none(session_manager, test_vault):
    """None or empty returns vault root."""
    assert session_manager.resolve_working_directory(None) == test_vault
    assert session_manager.resolve_working_directory("") == test_vault


def test_resolve_working_directory_relative(session_manager, test_vault):
    """Relative path is resolved under vault."""
    # Create the target directory so resolve() works
    projects = test_vault / "Projects" / "my-repo"
    projects.mkdir(parents=True)

    result = session_manager.resolve_working_directory("Projects/my-repo")
    assert result == test_vault / "Projects" / "my-repo"


def test_resolve_working_directory_vault_prefix(session_manager, test_vault):
    """/vault/... paths are translated to real vault path."""
    projects = test_vault / "Projects" / "my-repo"
    projects.mkdir(parents=True)

    result = session_manager.resolve_working_directory("/vault/Projects/my-repo")
    assert result == test_vault / "Projects" / "my-repo"


def test_resolve_working_directory_absolute(session_manager, test_vault):
    """Absolute paths (non /vault/) are used as-is."""
    result = session_manager.resolve_working_directory(str(test_vault / "Chat"))
    assert result == test_vault / "Chat"


def test_resolve_working_directory_escapes_vault(session_manager, test_vault):
    """Paths that escape the vault fall back to vault root."""
    result = session_manager.resolve_working_directory("../../etc/passwd")
    assert result == test_vault
