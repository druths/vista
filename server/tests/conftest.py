"""Test configuration.

The integration tests run against a real Ark server (see
docker-compose.test.yml) rather than a mock, so the assumptions Vista makes
about Ark's filesystem API are actually verified.
"""

from __future__ import annotations

import os
import uuid

import pytest

ARK_URL = os.environ.get("VISTA_TEST_ARK_URL", "")
ARK_TOKEN = os.environ.get("VISTA_TEST_ARK_TOKEN", "")
ARK_AGENT = os.environ.get("VISTA_TEST_ARK_AGENT", "scribe")

requires_ark = pytest.mark.skipif(
    not ARK_URL, reason="set VISTA_TEST_ARK_URL to run integration tests against Ark"
)


@pytest.fixture
def ark_client():
    from vista.ark import ArkClient

    return ArkClient(ARK_URL, ARK_TOKEN, ARK_AGENT)


@pytest.fixture
def scratch() -> str:
    """A unique workspace-relative directory for one test to play in."""
    return f"vista-tests/{uuid.uuid4().hex[:12]}"


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(scope="session", autouse=True)
def _sweep_scratch_roots():
    """Remove the directories the suite works in once it finishes.

    Each test cleans up its own subdirectory, but the shared parents would
    otherwise accumulate in the agent workspace and show up in the settings
    folder browser.
    """
    yield
    if not ARK_URL:
        return

    import asyncio

    from vista.ark import ArkClient, ArkError

    async def sweep() -> None:
        client = ArkClient(ARK_URL, ARK_TOKEN, ARK_AGENT)
        for root in ("vista-tests", "vista-api-tests"):
            try:
                await client.delete(root)
            except ArkError:
                pass

    asyncio.run(sweep())
