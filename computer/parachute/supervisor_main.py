"""Supervisor entry point (python -m parachute.supervisor)."""

import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def main():
    """Run supervisor service."""
    import uvicorn

    logger.info("Starting Parachute Supervisor on http://0.0.0.0:3334")

    uvicorn.run(
        "parachute.supervisor:app",
        host="0.0.0.0",  # Listen on all interfaces for remote access
        port=3334,
        log_level="info",
    )


if __name__ == "__main__":
    main()
