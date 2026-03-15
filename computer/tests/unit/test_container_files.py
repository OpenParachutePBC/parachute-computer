"""
Tests for container file browser API helpers and endpoints.
"""

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from parachute.api.container_files import (
    _get_home_dir,
    _resolve_safe_path,
)


# ---------------------------------------------------------------------------
# _resolve_safe_path tests
# ---------------------------------------------------------------------------


class TestResolveSafePath:
    def test_normal_path(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        (home / "subdir").mkdir()
        result = _resolve_safe_path(home, "subdir")
        assert result == (home / "subdir").resolve()

    def test_leading_slash_stripped(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        (home / "file.txt").touch()
        result = _resolve_safe_path(home, "/file.txt")
        assert result == (home / "file.txt").resolve()

    def test_traversal_blocked(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        with pytest.raises(HTTPException) as exc_info:
            _resolve_safe_path(home, "../etc/passwd")
        assert exc_info.value.status_code == 403

    def test_double_dot_in_middle_blocked(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        (home / "subdir").mkdir()
        with pytest.raises(HTTPException) as exc_info:
            _resolve_safe_path(home, "subdir/../../etc/passwd")
        assert exc_info.value.status_code == 403

    def test_sibling_dir_prefix_blocked(self, tmp_path):
        """Regression: 'homeevil' must not pass check when home is 'home'."""
        home = tmp_path / "home"
        home.mkdir()
        (tmp_path / "homeevil").mkdir()
        (tmp_path / "homeevil" / "secret.txt").touch()
        with pytest.raises(HTTPException) as exc_info:
            _resolve_safe_path(home, "../homeevil/secret.txt")
        assert exc_info.value.status_code == 403

    def test_empty_path(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        result = _resolve_safe_path(home, "")
        assert result == home.resolve()


# ---------------------------------------------------------------------------
# _get_home_dir tests
# ---------------------------------------------------------------------------


class TestGetHomeDir:
    def test_correct_path(self):
        with patch("parachute.api.container_files.get_settings") as mock_settings:
            mock_settings.return_value.parachute_dir = Path("/fake/.parachute")
            result = _get_home_dir("my-env")
            assert result == Path("/fake/.parachute/sandbox/envs/my-env/home")


# ---------------------------------------------------------------------------
# Integration tests (using tmp dirs, no Docker)
# ---------------------------------------------------------------------------


@pytest.fixture
def home_dir(tmp_path):
    """Create a temporary container home directory with some files."""
    home = tmp_path / "home"
    home.mkdir()
    (home / "file.txt").write_text("hello world")
    (home / "subdir").mkdir()
    (home / "subdir" / "nested.txt").write_text("nested content")
    (home / ".hidden").write_text("secret")
    return home


@pytest.fixture
def mock_app(home_dir):
    """Create a mock FastAPI app with session store that returns a container env."""
    app = MagicMock()
    mock_env = MagicMock()
    mock_env.slug = "test-env"

    store = AsyncMock()
    store.get_container = AsyncMock(return_value=mock_env)
    app.state.session_store = store
    return app


@pytest.fixture
def mock_request(mock_app):
    """Create a mock request with app state."""
    request = MagicMock()
    request.app = mock_app
    return request


class TestListFiles:
    @pytest.mark.asyncio
    async def test_list_root(self, mock_request, home_dir):
        from parachute.api.container_files import list_files

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await list_files(mock_request, "test-env", path=None, includeHidden=False)

        assert result.slug == "test-env"
        assert result.path == ""
        names = [e.name for e in result.entries]
        assert "file.txt" in names
        assert "subdir" in names
        assert ".hidden" not in names

    @pytest.mark.asyncio
    async def test_list_with_hidden(self, mock_request, home_dir):
        from parachute.api.container_files import list_files

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await list_files(mock_request, "test-env", path=None, includeHidden=True)

        names = [e.name for e in result.entries]
        assert ".hidden" in names

    @pytest.mark.asyncio
    async def test_list_subdir(self, mock_request, home_dir):
        from parachute.api.container_files import list_files

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await list_files(mock_request, "test-env", path="subdir", includeHidden=False)

        assert result.path == "subdir"
        names = [e.name for e in result.entries]
        assert "nested.txt" in names

    @pytest.mark.asyncio
    async def test_list_nonexistent(self, mock_request, home_dir):
        from parachute.api.container_files import list_files

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            with pytest.raises(HTTPException) as exc_info:
                await list_files(mock_request, "test-env", path="nope", includeHidden=False)
            assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_slug_not_found(self, mock_request, home_dir):
        from parachute.api.container_files import list_files

        mock_request.app.state.session_store.get_container = AsyncMock(return_value=None)
        with pytest.raises(HTTPException) as exc_info:
            await list_files(mock_request, "bad-slug", path=None, includeHidden=False)
        assert exc_info.value.status_code == 404


class TestDownloadFile:
    @pytest.mark.asyncio
    async def test_download(self, mock_request, home_dir):
        from parachute.api.container_files import download_file

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            response = await download_file(mock_request, "test-env", path="file.txt")

        assert response.filename == "file.txt"

    @pytest.mark.asyncio
    async def test_download_not_found(self, mock_request, home_dir):
        from parachute.api.container_files import download_file

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            with pytest.raises(HTTPException) as exc_info:
                await download_file(mock_request, "test-env", path="nope.txt")
            assert exc_info.value.status_code == 404


class TestMakeDirectory:
    @pytest.mark.asyncio
    async def test_mkdir(self, mock_request, home_dir):
        from parachute.api.container_files import make_directory

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await make_directory(mock_request, "test-env", path="newdir/nested")

        assert result.success is True
        assert (home_dir / "newdir" / "nested").is_dir()


class TestDeleteFile:
    @pytest.mark.asyncio
    async def test_delete_file(self, mock_request, home_dir):
        from parachute.api.container_files import delete_file

        assert (home_dir / "file.txt").exists()
        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await delete_file(mock_request, "test-env", path="file.txt")

        assert result.success is True
        assert not (home_dir / "file.txt").exists()

    @pytest.mark.asyncio
    async def test_delete_directory(self, mock_request, home_dir):
        from parachute.api.container_files import delete_file

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            result = await delete_file(mock_request, "test-env", path="subdir")

        assert result.success is True
        assert not (home_dir / "subdir").exists()

    @pytest.mark.asyncio
    async def test_delete_home_blocked(self, mock_request, home_dir):
        from parachute.api.container_files import delete_file

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            with pytest.raises(HTTPException) as exc_info:
                await delete_file(mock_request, "test-env", path="")
            assert exc_info.value.status_code == 400

    @pytest.mark.asyncio
    async def test_delete_not_found(self, mock_request, home_dir):
        from parachute.api.container_files import delete_file

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            with pytest.raises(HTTPException) as exc_info:
                await delete_file(mock_request, "test-env", path="nope")
            assert exc_info.value.status_code == 404


class TestUploadFiles:
    @pytest.mark.asyncio
    async def test_upload(self, mock_request, home_dir):
        from parachute.api.container_files import upload_files

        mock_file = MagicMock(spec=["read", "filename"])
        mock_file.filename = "uploaded.txt"
        mock_file.read = AsyncMock(return_value=b"file content")

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            results = await upload_files(mock_request, "test-env", files=[mock_file], path=None)

        assert len(results) == 1
        assert results[0].success is True
        assert (home_dir / "uploaded.txt").read_bytes() == b"file content"

    @pytest.mark.asyncio
    async def test_upload_too_large(self, mock_request, home_dir):
        from parachute.api.container_files import upload_files, MAX_UPLOAD_SIZE

        mock_file = MagicMock(spec=["read", "filename"])
        mock_file.filename = "big.bin"
        mock_file.read = AsyncMock(return_value=b"x" * (MAX_UPLOAD_SIZE + 1))

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            results = await upload_files(mock_request, "test-env", files=[mock_file], path=None)

        assert len(results) == 1
        assert results[0].success is False
        assert "limit" in results[0].message

    @pytest.mark.asyncio
    async def test_upload_to_subdir(self, mock_request, home_dir):
        from parachute.api.container_files import upload_files

        mock_file = MagicMock(spec=["read", "filename"])
        mock_file.filename = "data.csv"
        mock_file.read = AsyncMock(return_value=b"a,b,c")

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            results = await upload_files(mock_request, "test-env", files=[mock_file], path="uploads/2024")

        assert results[0].success is True
        assert (home_dir / "uploads" / "2024" / "data.csv").read_bytes() == b"a,b,c"

    @pytest.mark.asyncio
    async def test_upload_traversal_filename_stripped(self, mock_request, home_dir):
        """Regression: malicious filename with ../ must be stripped to basename."""
        from parachute.api.container_files import upload_files

        mock_file = MagicMock(spec=["read", "filename"])
        mock_file.filename = "../../etc/evil.txt"
        mock_file.read = AsyncMock(return_value=b"payload")

        with patch("parachute.api.container_files._get_home_dir", return_value=home_dir):
            results = await upload_files(mock_request, "test-env", files=[mock_file], path=None)

        assert results[0].success is True
        # File should be written as "evil.txt" in home dir, not outside it
        assert (home_dir / "evil.txt").read_bytes() == b"payload"
        assert not (home_dir.parent.parent / "etc" / "evil.txt").exists()
