"""FastAPI application entrypoint.

Safety invariant: the API talks only to the bundled local Anvil chain. The RPC
URL comes from process configuration (never from a request body) and is
validated at startup by `app.config.Settings`.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes import health as health_routes
from app.config import get_settings

API_PREFIX = "/api"

logger = logging.getLogger(__name__)


def configure_logging(level: str) -> None:
    """Configure structured-friendly root logging."""
    logging.basicConfig(
        level=level.upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Application lifespan: log the pinned lab chain ID on boot."""
    settings = get_settings()
    configure_logging(settings.log_level)
    logger.info(
        "ChainGuard API starting; attack engine pinned to chain id %s",
        settings.expected_chain_id,
    )
    yield
    logger.info("ChainGuard API shutting down")


def create_app() -> FastAPI:
    """Build the FastAPI application."""
    settings = get_settings()
    app = FastAPI(
        title="ChainGuard API",
        version="0.1.0",
        summary="Smart contract attack simulator & security analyzer (local chain only)",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(health_routes.router, prefix=API_PREFIX)
    return app


app = create_app()
