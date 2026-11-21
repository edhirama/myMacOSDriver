#!/usr/bin/env python3
"""Drives the fixture app (Sources/DriverFixture): standard controls plus two custom-drawn
canvases that can only be reached with real mouse and key events.

    scripts/package_fixture.sh
    open build/MacDriver.app --args --test-ops     # test ops are only needed for the mirror checks
    python3 Tests/E2E/fixture.py

The "strict" canvas refuses first clicks while its app is inactive (the AppKit default), which
is the hard case for a driver that never activates the target app.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
from driver import Driver  # noqa: E402

APP = os.path.join(ROOT, "build", "DriverFixture.app")
d = Driver()
results = []


def check(label, cond, detail=""):
    results.append(bool(cond))
    print(f"[{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail and not cond else ""))


def call(name, **arguments):
    return d.call({"name": name, "arguments": arguments})


def frontmost():
    """The app that has the user's keyboard, as the system sees it."""
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    return subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True).stdout.strip()


def main():
    if not os.path.isdir(APP):
        sys.exit("Build the fixture first: scripts/package_fixture.sh")
    front_before = frontmost()
    subprocess.run(["pkill", "-f", "DriverFixture.app/Contents/MacOS/DriverFixture"])
    time.sleep(0.5)

    r = call("computer_open", app=APP)
    wins = r.get("result", {}).get("windows", [])
    check("open: fixture window created on the virtual monitor", r["ok"] and wins and wins[0]["status"] == "created" and wins[0]["placement"] == "moved_to_target", r.get("error") or wins)
    win = wins[0]["window"]

    def nodes():
        out = []

        def walk(n):
            out.append(n)
            for c in n.get("children", []):
                walk(c)
        walk(call("computer_snapshot", window=win)["result"]["tree"])
        return out

    def label(prefix):
        return next((n["value"] for n in nodes() if str(n.get("value", "")).startswith(prefix)), None)

    def node(**want):
        return next(n for n in nodes() if all(n.get(k) == v for k, v in want.items()))

    def state(name):
        """'easy: clicks=1 count=1 ...' -> {'clicks': '1', 'count': '1', ...}"""
        return dict(kv.split("=", 1) for kv in label(name + ":").split()[1:])

    shot = call("computer_screenshot")["result"]
    s = shot["scale"]

    def at(f, dx=0.5, dy=0.5):
        return {"in": shot["screenshot"], "x": (f["x"] + f["width"] * dx) * s, "y": (f["y"] + f["height"] * dy) * s}

    # --- standard controls ----------------------------------------------------
    button = node(role="AXButton", name="Increment")
    r = call("computer_click", ref=button["ref"])
    check("button by ref: pressed once", r["ok"] and r["result"]["method"] == "ax_press" and label("counter:") == "counter: 1", (r.get("result", {}).get("method"), label("counter:")))
    r = call("computer_click", **at(button["frame"]))
    check("button by position: pressed once", r["ok"] and label("counter:") == "counter: 2", (r.get("result", {}).get("method"), label("counter:")))
    r = call("computer_click", **at(node(role="AXCheckBox")["frame"], dx=0.1))
    check("checkbox by position: toggled", r["ok"] and label("checkbox:") == "checkbox: on", label("checkbox:"))
    field = node(role="AXTextField", name="name-field")
    call("computer_click", ref=field["ref"])
    r = call("computer_type", text="hello")
    check("text field: click then type", r["ok"] and node(role="AXTextField", name="name-field").get("value") == "hello", node(role="AXTextField", name="name-field").get("value"))

    # --- custom views: only real events can reach these ------------------------
    for name in ("easy", "strict"):
        f = node(name=name + "-canvas")["frame"]
        r = call("computer_click", **at(f))
        st = state(name)
        check(f"{name} canvas: click delivered as a mouse event", r["ok"] and r["result"]["method"] == "events" and st["clicks"] == "1" and st["count"] == "1", (r.get("result", {}).get("method"), st))
        check(f"{name} canvas: click reported as confirmed", r["effect"]["confirmed"], r["effect"])
        r = call("computer_click", **at(f), count=2)
        st = state(name)
        check(f"{name} canvas: double-click arrives as two clicks, the second with count 2", st["clicks"] == "3" and st["count"] == "2", st)
        r = call("computer_click", **at(f), button="right")
        check(f"{name} canvas: right-click", state(name)["right"] == "1", state(name))
        r = call("computer_drag", **{"in": shot["screenshot"]}, path=[{"x": (f["x"] + 30) * s, "y": (f["y"] + 30) * s}, {"x": (f["x"] + 130) * s, "y": (f["y"] + 70) * s}])
        check(f"{name} canvas: drag covers the requested distance", r["ok"] and state(name)["drag"] == "100,40", state(name))
        r = call("computer_scroll", **at(f), direction="down", amount=3)
        check(f"{name} canvas: wheel events delivered", r["ok"] and r["result"]["method"] == "events" and state(name)["wheel"] == "-3", (r.get("result", {}).get("method"), state(name)))
        call("computer_click", **at(f))
        r = call("computer_type", text="ab")
        check(f"{name} canvas: keys go to the view that was clicked", r["ok"] and state(name)["keys"] == "ab", state(name))

    # --- scrolling a real scroll view ------------------------------------------
    area = node(role="AXScrollArea")["frame"]
    r = call("computer_scroll", **at(area), direction="down", amount=5)
    pos = int(label("scroll:").split()[1])
    check("scroll view: content moved", r["ok"] and pos > 0 and r["effect"]["confirmed"], (pos, r.get("result", {}).get("method")))

    # --- window drag by the title bar ------------------------------------------
    w0 = node(role="AXWindow")["frame"]
    r = call("computer_drag", **{"in": shot["screenshot"]}, path=[{"x": (w0["x"] + 280) * s, "y": (w0["y"] + 12) * s}, {"x": (w0["x"] + 380) * s, "y": (w0["y"] + 72) * s}])
    w1 = r.get("result", {}).get("window_frame", {})
    check("title-bar drag moves the window by the dragged distance", r["ok"] and abs(w1.get("x", 0) - w0["x"] - 100) <= 3 and abs(w1.get("y", 0) - w0["y"] - 60) <= 3, (w0, w1, r.get("result", {}).get("method")))

    # --- the human in the mirror, on a custom view ------------------------------
    if d._test_control(True).get("ok"):
        f = node(name="strict-canvas")["frame"]
        before = int(state("strict")["clicks"])
        d._round_trip({"op": "test_user_input", "kind": "click", "x": f["x"] + 60, "y": f["y"] + 40}, 10)
        time.sleep(0.4)
        check("mirror: the user's click reaches the strict canvas", int(state("strict")["clicks"]) == before + 1, state("strict"))
        d._test_control(False)
    else:
        print("[SKIP] mirror checks (host is not running with --test-ops)")

    # --- the user was never disturbed -------------------------------------------
    check("the user's frontmost app never changed", frontmost() == front_before, (front_before, frontmost()))
    check("no keys or buttons left held", d.status()["result"]["held_inputs"] == 0)

    r = call("computer_close", window=win)
    check("close: fixture window closed", r["ok"] and r["result"]["status"] == "closed", r.get("result"))

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
