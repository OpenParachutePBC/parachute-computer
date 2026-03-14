"""
Server-side speech-to-text transcription service.

Delegates to platform-specific backends:
- macOS: parakeet-mlx (Metal GPU acceleration via Apple MLX)
- Linux: sherpa-onnx (future — CPU-based ONNX Runtime)

The TranscriptionService is a singleton initialized at server startup
and published to the InterfaceRegistry as "TranscriptionService".
"""

import asyncio
import logging
import sys
from pathlib import Path
from typing import Protocol, runtime_checkable

from parachute.config import Settings

logger = logging.getLogger(__name__)

# Default model for parakeet-mlx backend
DEFAULT_MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"


@runtime_checkable
class TranscriptionBackend(Protocol):
    """Interface for transcription backends."""

    async def initialize(self) -> None:
        """Load the model. Called once at startup."""
        ...

    async def transcribe(self, audio_path: Path) -> str:
        """Transcribe an audio file. Returns text."""
        ...

    async def transcribe_bytes(self, audio_bytes: bytes) -> str:
        """Transcribe from raw audio bytes. Returns text."""
        ...


class TranscriptionService:
    """Server-side speech-to-text. Delegates to platform-specific backend."""

    def __init__(self, backend: TranscriptionBackend):
        self._backend = backend

    @classmethod
    def from_config(cls, settings: Settings) -> "TranscriptionService | None":
        """Auto-detect platform and select best available backend.

        Returns None if no backend is available (e.g., parakeet-mlx not
        installed on macOS, or running on an unsupported platform).
        """
        # Check if transcription is disabled via config
        if hasattr(settings, "transcription_enabled") and not settings.transcription_enabled:
            logger.info("Transcription disabled via config")
            return None

        # Get model ID from config or use default
        model_id = getattr(settings, "transcription_model_id", None) or DEFAULT_MODEL_ID

        backend = _detect_backend(model_id)
        if backend is None:
            return None
        return cls(backend)

    async def initialize(self) -> None:
        """Load the model. Call once at startup."""
        await self._backend.initialize()

    async def transcribe(self, audio_path: Path) -> str:
        """Transcribe an audio file. Returns text."""
        return await self._backend.transcribe(audio_path)

    async def transcribe_bytes(self, audio_bytes: bytes) -> str:
        """Transcribe from raw audio bytes. Returns text."""
        return await self._backend.transcribe_bytes(audio_bytes)

    async def shutdown(self) -> None:
        """Shut down the backend, waiting for in-flight work."""
        if hasattr(self._backend, "shutdown"):
            await self._backend.shutdown()


def _detect_backend(model_id: str) -> TranscriptionBackend | None:
    """Select backend: parakeet-mlx on macOS, sherpa-onnx on Linux (future)."""
    if sys.platform == "darwin":
        try:
            from parachute.core.transcription_mlx import ParakeetMLXBackend

            return ParakeetMLXBackend(model_id=model_id)
        except ImportError:
            logger.warning(
                "parakeet-mlx not installed — transcription unavailable. "
                "Install with: pip install parakeet-mlx"
            )
            return None
    else:
        # Future: sherpa-onnx backend for Linux
        logger.info(
            f"Transcription: no backend available for platform '{sys.platform}'. "
            f"Server-side transcription requires macOS with parakeet-mlx."
        )
        return None
