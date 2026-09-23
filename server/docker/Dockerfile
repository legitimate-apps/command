# syntax=docker/dockerfile:1.7
# Two-stage build: uv resolves deps + installs the
# project non-editable into /opt/venv in the builder, then a slim python
# runtime picks the self-contained venv up unchanged. Lean by construction.

FROM ghcr.io/astral-sh/uv:0.10.8-python3.12-trixie-slim AS builder

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_NO_CACHE=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /build

# Lockfile + metadata first so dependency resolution caches across code changes.
COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Then the source, installed NON-editable so the venv is self-contained.
COPY src/ ./src/
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-editable


FROM python:3.12-slim-trixie AS runtime

# Non-root, UID/GID 1000 (lines up with LinuxServer-style volume mounts).
RUN groupadd --system --gid 1000 command \
    && useradd --system --uid 1000 --gid command --create-home --shell /usr/sbin/nologin command \
    && mkdir -p /data && chown command:command /data

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    COMMAND_DB_PATH=/data/command.db \
    COMMAND_HTTP_HOST=0.0.0.0 \
    COMMAND_ENVIRONMENT=prod

USER command
WORKDIR /home/command
VOLUME ["/data"]
EXPOSE 8000

LABEL org.opencontainers.image.source="https://github.com/legitimate-apps/command" \
      org.opencontainers.image.description="Command planner backend: REST API + MCP over SQLite" \
      org.opencontainers.image.licenses="MIT"

# Runs uvicorn (single worker) serving both the REST API and the mounted MCP app.
ENTRYPOINT ["command-server"]
