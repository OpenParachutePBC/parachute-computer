"""
Unit tests for para ID generation.
"""

import pytest

from parachute.lib.para_id import generate_para_id, is_valid_para_id, parse_para_id


def test_generate_para_id_format():
    """Test that generated para IDs have correct format."""
    para_id = generate_para_id()

    assert para_id.startswith("para:")
    assert len(para_id) == 13  # "para:" + 8 chars


def test_generate_para_id_uniqueness():
    """Test that generated para IDs are unique."""
    ids = set()
    for _ in range(1000):
        para_id = generate_para_id()
        assert para_id not in ids
        ids.add(para_id)


def test_is_valid_para_id():
    """Test para ID validation."""
    # Valid IDs
    assert is_valid_para_id("para:abcd1234") is True
    assert is_valid_para_id("para:00000000") is True
    assert is_valid_para_id("para:zzzzzzzz") is True

    # Invalid IDs
    assert is_valid_para_id("para:abc") is False  # Too short
    assert is_valid_para_id("para:abcdefghi") is False  # Too long
    assert is_valid_para_id("para:ABCD1234") is False  # Uppercase
    assert is_valid_para_id("abc:12345678") is False  # Wrong prefix
    assert is_valid_para_id("12345678") is False  # No prefix
    assert is_valid_para_id("") is False
    assert is_valid_para_id(None) is False


def test_parse_para_id():
    """Test parsing para IDs."""
    result = parse_para_id("para:abcd1234")

    assert result is not None
    assert result["prefix"] == "para"
    assert result["id"] == "abcd1234"


def test_parse_invalid_para_id():
    """Test parsing invalid para IDs returns None."""
    assert parse_para_id("invalid") is None
    assert parse_para_id("para:abc") is None
    assert parse_para_id("") is None


def test_generated_id_is_valid():
    """Test that generated IDs pass validation."""
    for _ in range(100):
        para_id = generate_para_id()
        assert is_valid_para_id(para_id)
