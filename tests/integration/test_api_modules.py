"""
Integration tests for modules API.
"""

import pytest


def test_list_modules(test_client):
    """Test listing modules."""
    response = test_client.get("/api/modules")

    assert response.status_code == 200
    data = response.json()
    assert "modules" in data
    assert isinstance(data["modules"], list)


def test_get_module_prompt_nonexistent(test_client):
    """Test getting prompt for module without CLAUDE.md."""
    response = test_client.get("/api/modules/chat/prompt")

    assert response.status_code == 200
    data = response.json()
    assert data["exists"] is False
    assert data["content"] is None
    assert "defaultPrompt" in data


def test_update_module_prompt(test_client):
    """Test updating module prompt."""
    response = test_client.put(
        "/api/modules/chat/prompt",
        json={"content": "# Custom Prompt\n\nThis is a test prompt."},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["success"] is True

    # Verify it was saved
    response = test_client.get("/api/modules/chat/prompt")
    data = response.json()
    assert data["exists"] is True
    assert "Custom Prompt" in data["content"]


def test_reset_module_prompt(test_client):
    """Test resetting module prompt."""
    # First set a custom prompt
    test_client.put(
        "/api/modules/chat/prompt",
        json={"content": "Custom content"},
    )

    # Then reset it
    response = test_client.put(
        "/api/modules/chat/prompt",
        json={"reset": True},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["reset"] is True

    # Verify it was reset
    response = test_client.get("/api/modules/chat/prompt")
    data = response.json()
    assert data["exists"] is False


def test_update_prompt_missing_content(test_client):
    """Test updating prompt without content or reset."""
    response = test_client.put(
        "/api/modules/chat/prompt",
        json={},
    )

    assert response.status_code == 400


def test_search_module(test_client):
    """Test module search (placeholder)."""
    response = test_client.get("/api/modules/chat/search?q=test")

    assert response.status_code == 200
    data = response.json()
    assert "results" in data


def test_get_module_stats(test_client):
    """Test getting module stats."""
    response = test_client.get("/api/modules/chat/stats")

    assert response.status_code == 200
    data = response.json()
    assert data["module"] == "chat"
    assert "fileCount" in data


def test_get_nonexistent_module_stats(test_client):
    """Test getting stats for nonexistent module."""
    response = test_client.get("/api/modules/nonexistent/stats")

    assert response.status_code == 404
