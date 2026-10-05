"""Placeholder server for the uploaded-Solidity sandbox.

Milestone 0 scope: this exists so the Compose security topology
(`network_mode: none`, read-only root filesystem, dropped capabilities, tmpfs
workspace, non-root user) can be built and validated. The real
compile-and-statically-analyze pipeline lands in Prompt 10.

The sandbox never deploys and never executes uploaded code.
"""

from __future__ import annotations

import json
import os
import socket
import threading

SOCKET_PATH = os.environ.get("ANALYZER_SOCKET", "/run/chainguard/analyzer.sock")
BACKLOG = 8
MAX_REQUEST_BYTES = 64 * 1024


def _handle(connection: socket.socket) -> None:
    """Answer a single request. Replaced by the analyzer pipeline in Prompt 10."""
    with connection:
        try:
            request = connection.recv(MAX_REQUEST_BYTES).decode("utf-8", errors="replace")
        except OSError:
            return

        payload = json.dumps(
            {
                "status": "not_implemented",
                "detail": "Analyzer pipeline lands in Prompt 10; this sandbox never executes uploads.",
                "bytes_received": len(request),
            }
        )
        connection.sendall(payload.encode("utf-8"))


def serve() -> None:
    """Serve the unix socket used by the worker to reach this container."""
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        server.listen(BACKLOG)
        print(f"analyzer sandbox listening on {SOCKET_PATH}", flush=True)

        while True:
            connection, _ = server.accept()
            threading.Thread(target=_handle, args=(connection,), daemon=True).start()


if __name__ == "__main__":
    serve()