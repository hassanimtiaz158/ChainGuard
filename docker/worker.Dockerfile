# syntax=docker/dockerfile:1
#
# ChainGuard analysis worker. Same dependency set as the API image; only the
# entrypoint differs. Analysis jobs are dispatched over RQ by the API.

FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.11.23 /uv /usr/local/bin/uv

WORKDIR /app

COPY pyproject.toml README.md ./
RUN uv sync --no-dev

COPY app ./app
COPY worker ./worker

CMD ["python", "-m", "worker.main"]