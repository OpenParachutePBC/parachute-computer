"""
Integration tests for session API.
"""

import pytest


def test_list_sessions_empty(test_client):
    """Test listing sessions when empty."""
    response = test_client.get("/api/chat")

    assert response.status_code == 200
    data = response.json()
    assert "sessions" in data
    assert isinstance(data["sessions"], list)


def test_get_nonexistent_session(test_client):
    """Test getting a session that doesn't exist."""
    response = test_client.get("/api/chat/nonexistent-session-id")

    assert response.status_code == 404
    data = response.json()
    assert "detail" in data


def test_delete_nonexistent_session(test_client):
    """Test deleting a session that doesn't exist."""
    response = test_client.delete("/api/chat/nonexistent-session-id")

    assert response.status_code == 404


def test_archive_nonexistent_session(test_client):
    """Test archiving a session that doesn't exist."""
    response = test_client.post("/api/chat/nonexistent-session-id/archive")

    assert response.status_code == 404


def test_list_sessions_with_filters(test_client):
    """Test listing sessions with query parameters."""
    response = test_client.get("/api/chat?module=chat&limit=10")

    assert response.status_code == 200
    data = response.json()
    assert "sessions" in data


def test_list_archived_sessions(test_client):
    """Test listing archived sessions."""
    response = test_client.get("/api/chat?archived=true")

    assert response.status_code == 200
    data = response.json()
    assert "sessions" in data
