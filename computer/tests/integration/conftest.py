"""
Integration test fixtures with ephemeral graph database.

Provides a FastAPI test client backed by a temporary Kuzu graph,
so brain API endpoints can be tested without touching the live DB.
"""

import asyncio
from pathlib import Path
from typing import AsyncGenerator

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from parachute.core.interfaces import get_registry
from parachute.db.brain import BrainService
from parachute.db.brain_chat_store import BrainChatStore


@pytest_asyncio.fixture
async def brain_graph(tmp_path: Path) -> AsyncGenerator[BrainService, None]:
    """Create an ephemeral Kuzu graph for testing."""
    db_path = tmp_path / "test-graph" / "test.kz"
    graph = BrainService(db_path=db_path)
    await graph.connect()
    yield graph
    await graph.close()


@pytest_asyncio.fixture
async def brain_store(brain_graph: BrainService) -> BrainChatStore:
    """Create a BrainChatStore with full schema initialized.

    Includes Exchange table and HAS_EXCHANGE relationship which are
    normally created by the chat module on_load.
    """
    store = BrainChatStore(brain_graph)
    await store.ensure_schema()

    # Exchange table (normally created by chat module)
    await brain_graph.ensure_node_table(
        "Exchange",
        {
            "exchange_id": "STRING",
            "session_id": "STRING",
            "exchange_number": "STRING",
            "description": "STRING",
            "user_message": "STRING",
            "ai_response": "STRING",
            "context": "STRING",
            "session_title": "STRING",
            "tools_used": "STRING",
            "created_at": "STRING",
        },
        primary_key="exchange_id",
    )
    await brain_graph.ensure_rel_table("HAS_EXCHANGE", "Chat", "Exchange")

    return store


@pytest_asyncio.fixture
async def brain_client(
    brain_graph: BrainService,
    brain_store: BrainChatStore,
) -> AsyncGenerator[AsyncClient, None]:
    """
    AsyncClient wired to the FastAPI app with an ephemeral graph.

    Publishes the test BrainService into the global registry so that
    brain API endpoints (which call get_registry().get("BrainDB"))
    resolve to our ephemeral DB instead of the live one.
    """
    registry = get_registry()
    old_brain = registry.get("BrainDB")
    old_store = registry.get("ChatStore")

    registry.publish("BrainDB", brain_graph)
    registry.publish("ChatStore", brain_store)

    try:
        from parachute.api.brain import router
        from fastapi import FastAPI

        # Minimal app with just the brain router
        test_app = FastAPI()
        test_app.include_router(router, prefix="/api")

        transport = ASGITransport(app=test_app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    finally:
        # Restore previous registry state
        if old_brain is not None:
            registry.publish("BrainDB", old_brain)
        if old_store is not None:
            registry.publish("ChatStore", old_store)
