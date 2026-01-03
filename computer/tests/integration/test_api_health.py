"""
Integration tests for health API.
"""

import pytest


def test_health_check(test_client):
    """Test basic health check."""
    response = test_client.get("/api/health")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "timestamp" in data


def test_health_check_detailed(test_client):
    """Test detailed health check."""
    response = test_client.get("/api/health?detailed=true")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "vault" in data
    assert "uptime" in data


def test_root_endpoint(test_client):
    """Test root endpoint."""
    response = test_client.get("/")

    assert response.status_code == 200
    data = response.json()
    assert data["name"] == "Parachute Base Server"
    assert data["status"] == "running"
