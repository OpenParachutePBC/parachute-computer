"""
Parakeet V3 transcription backend using Apple MLX.

Uses parakeet-mlx for Metal GPU-accelerated speech-to-text on macOS.
Model auto-downloads from HuggingFace Hub on first use and is cached
in ~/.cache/huggingface/.

Requires: pip install parakeet-mlx
Requires: FFmpeg installed (brew install ffmpeg)
"""

import asyncio
import logging
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


class ParakeetMLXBackend:
    """Parakeet V3 on Apple MLX — Metal GPU acceleration."""

    def __init__(self, model_id: str = "mlx-community/parakeet-tdt-0.6b-v3"):
        self._model_id = model_id
        self._model: Any = None
        self._executor = ThreadPoolExecutor(max_workers=2)

    async def initialize(self) -> None:
        """Load the Parakeet model. Downloads from HuggingFace on first use."""
        loop = asyncio.get_running_loop()
        logger.info(
            f"Loading transcription model '{self._model_id}' "
            f"(first run will download ~1.2 GB)..."
        )
        self._model = await loop.run_in_executor(
            self._executor, self._load_model
        )
        logger.info(f"Transcription model loaded: {self._model_id}")

    def _load_model(self) -> Any:
        """Load the model (blocking — runs in executor)."""
        from parakeet_mlx import from_pretrained

        return from_pretrained(self._model_id)

    async def transcribe(self, audio_path: Path) -> str:
        """Transcribe an audio file. Returns text."""
        if self._model is None:
            raise RuntimeError("TranscriptionService not initialized — call initialize() first")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._transcribe_sync, audio_path
        )

    async def transcribe_bytes(self, audio_bytes: bytes) -> str:
        """Transcribe from raw audio bytes. Writes to temp file for parakeet-mlx."""
        if self._model is None:
            raise RuntimeError("TranscriptionService not initialized — call initialize() first")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._transcribe_bytes_sync, audio_bytes
        )

    async def shutdown(self) -> None:
        """Shut down the executor, waiting for in-flight transcriptions."""
        self._executor.shutdown(wait=True, cancel_futures=False)

    def _transcribe_sync(self, audio_path: Path) -> str:
        """Transcribe a file (blocking — runs in executor)."""
        result = self._model.transcribe(str(audio_path))
        return result.text

    def _transcribe_bytes_sync(self, audio_bytes: bytes) -> str:
        """Transcribe from bytes via temp file (blocking — runs in executor).

        parakeet-mlx uses FFmpeg for audio loading so it needs a file path.
        """
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            os.fsync(tmp.fileno())
            result = self._model.transcribe(tmp.name)
            return result.text
