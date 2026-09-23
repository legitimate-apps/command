"""MCP server: the agent-facing surface over the same core/ the REST API uses.

Streamable HTTP transport, per-account opaque-bearer auth, settings-driven
read/write/delete gating, and confirm-token handshakes for destructive ops.
"""
