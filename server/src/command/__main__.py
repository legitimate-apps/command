"""Entrypoint: serve the app with a single uvicorn worker (lean — Hard Rule 3)."""

from __future__ import annotations


def main() -> None:
    import uvicorn

    from .config import get_settings

    settings = get_settings()
    uvicorn.run(
        "command.app:app",
        host=settings.http_host,
        port=settings.http_port,
        log_level=settings.log_level.lower(),
        workers=1,
    )


if __name__ == "__main__":
    main()
