#!/usr/bin/env python3
"""Host-restart test for the persisted idempotency ledger. It kills and relaunches the host.

    open build/MacDriver.app --args --test-ops
    python3 Tests/E2E/recovery.py

A request that was running when the host died must not run again when the client retries it
under the same id after the restart; a request that had finished must be replayed.
"""
import os
import signal
import subprocess
import sys
import threading
import time
import uuid

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
from driver import Driver, DriverConnectionError  # noqa: E402

APP = os.path.join(ROOT, "build", "MacDriver.app")
# Fresh ids per run: the journal remembers the ids of earlier runs, as it should.
RUN = uuid.uuid4().hex[:8]
DONE, INTERRUPTED = f"recovery-done-{RUN}", f"recovery-interrupted-{RUN}"
d = Driver()
results = []


def check(label, cond, detail=""):
    results.append(bool(cond))
    print(f"[{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail and not cond else ""))


def host_pid():
    out = subprocess.run(["pgrep", "-f", "MacDriver.app/Contents/MacOS/MacDriverHost"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def wait_for_host(timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if d.status().get("ok"):
                return True
        except (DriverConnectionError, OSError):
            pass
        time.sleep(0.3)
    return False


def main():
    if not d._test_control(False).get("ok"):
        sys.exit("Launch the host with: open build/MacDriver.app --args --test-ops")

    # A finished request, to be replayed after the restart. Opening an app that is already
    # running moves nothing and creates nothing, so the test leaves no trace.
    done = d.call({"id": DONE, "name": "computer_open", "arguments": {"app": "Finder"}})
    check("request before the restart succeeded", done.get("ok"), done.get("error"))

    # A request that is running when the host dies. The user holds control, so it has started
    # (and is in the journal) but is paused before sending any input: nothing is left half-done.
    d._test_control(True)
    out = {}

    def run():
        try:
            out.update(d.call({"id": INTERRUPTED, "name": "computer_open", "arguments": {"app": "Finder"}, "timeout_ms": 30000}))
        except Exception as e:  # the connection dies with the host
            out["exception"] = type(e).__name__

    t = threading.Thread(target=run)
    t.start()
    time.sleep(1.0)
    check("request is in flight when the host is killed", d.status()["result"]["in_flight"] >= 1)
    pid = host_pid()
    os.kill(pid, signal.SIGKILL)
    t.join(timeout=15)
    check("client saw the host go away", "exception" in out or not out.get("ok", False), out)

    subprocess.run(["open", APP, "--args", "--test-ops"], check=True)
    check("host is back", wait_for_host() and host_pid() != pid)
    st = d.status()["result"]
    check("restarted host knows a request was interrupted", st.get("interrupted_requests", 0) >= 1, st.get("interrupted_requests"))
    check("restarted host starts with scripts in control", st["control"] == "agent")

    r = d.call({"id": INTERRUPTED, "name": "computer_open", "arguments": {"app": "Finder"}})
    check("interrupted request is not run again", not r["ok"] and r["error"]["code"] == "unknown_outcome" and r["dispatch"] == "unknown", r)
    r = d.call({"id": DONE, "name": "computer_open", "arguments": {"app": "Finder"}})
    check("finished request is replayed from the journal", r.get("ok") and r.get("replayed") is True, r)
    r = d.call({"id": DONE, "name": "computer_open", "arguments": {"app": "TextEdit"}})
    check("id reuse for a different request is still rejected", r["error"]["code"] == "id_conflict", r)
    r = d.call({"name": "computer_apps", "arguments": {}})
    check("new requests work after the restart", r.get("ok"), r.get("error"))

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
