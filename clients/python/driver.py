"""Python client for the MacDriver host.

    from driver import Driver
    driver = Driver()
    shot = driver.call({"name": "computer_screenshot", "arguments": {}})
    driver.call({"name": "computer_click",
                 "arguments": {"in": shot["result"]["screenshot"], "x": 300, "y": 200}})

`call` returns the response dict documented in docs/PROTOCOL.md. It never raises for tool
errors (check response["ok"]); it raises DriverConnectionError only when the host cannot be
reached after the configured retries.

Retries are safe: every request carries an id (generated here when absent) and the host's
idempotency ledger guarantees one execution per id, so re-sending after a dropped connection
returns the original result instead of repeating the action.
"""
from __future__ import annotations

import json
import os
import socket
import time
import uuid
from typing import Any, Dict, Optional

DEFAULT_SOCKET = os.environ.get(
    "MACDRIVER_SOCKET",
    os.path.expanduser("~/Library/Application Support/MacDriver/driver.sock"),
)


class DriverConnectionError(RuntimeError):
    pass


class Driver:
    def __init__(self, socket_path: str = DEFAULT_SOCKET, retries: int = 2, connect_timeout: float = 5.0):
        self.socket_path = socket_path
        self.retries = retries
        self.connect_timeout = connect_timeout

    # -- public API -------------------------------------------------------

    def call(self, request: Dict[str, Any], timeout: Optional[float] = None) -> Dict[str, Any]:
        """Executes one tool call: {"name": ..., "arguments": {...}, "id"?: ..., "timeout_ms"?: ...}."""
        if not isinstance(request, dict) or "name" not in request:
            raise ValueError("request must be a dict with a 'name'")
        req = dict(request)
        req.setdefault("id", "py-" + uuid.uuid4().hex)
        req.setdefault("arguments", {})
        # Socket wait must outlast the server-side timeout so we see its timeout response.
        wait = timeout if timeout is not None else (req.get("timeout_ms", 60_000) / 1000.0 + 10)
        last_error: Optional[Exception] = None
        for attempt in range(self.retries + 1):
            try:
                return self._round_trip(req, wait)
            except socket.timeout as e:
                # Waiting longer than the call's own timeout means something is wrong; do not
                # retry blindly. The host cancels the call about 2 s after this connection closes,
                # unless a retry with the same id attaches first.
                raise DriverConnectionError(f"no response within {wait:.0f}s for request {req['id']}") from e
            except (ConnectionError, OSError) as e:
                last_error = e
                time.sleep(0.2 * (attempt + 1))  # same id on retry: never executes twice
        raise DriverConnectionError(f"MacDriver host unreachable at {self.socket_path}: {last_error}")

    def cancel(self, request_id: str) -> Dict[str, Any]:
        return self._round_trip({"op": "cancel", "id": request_id}, 10)

    def status(self) -> Dict[str, Any]:
        return self._round_trip({"op": "status"}, 10)

    def tools(self) -> Dict[str, Any]:
        """Every tool with a JSON Schema of its arguments (`input_schema`), ready to hand to an agent."""
        return self._round_trip({"op": "tools"}, 10)

    def _test_control(self, take: bool) -> Dict[str, Any]:
        """Test-only: simulates Take Control / Give Back. Requires the host to run with --test-ops."""
        return self._round_trip({"op": "test_take_control" if take else "test_give_back"}, 10)

    # -- transport --------------------------------------------------------

    def _round_trip(self, message: Dict[str, Any], wait: float) -> Dict[str, Any]:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.connect_timeout)
        try:
            s.connect(self.socket_path)
            s.settimeout(wait)
            s.sendall((json.dumps(message) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(1 << 16)
                if not chunk:
                    raise ConnectionError("connection closed before a response arrived")
                buf += chunk
            return json.loads(buf.split(b"\n", 1)[0])
        finally:
            s.close()


driver = Driver()
"""Module-level instance so scripts can write `from driver import driver; driver.call({...})`."""
