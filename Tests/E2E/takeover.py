#!/usr/bin/env python3
"""Take Control / Give Back test. Requires the host to run with test ops enabled:

    open build/MacDriver.app --args --test-ops
    python3 Tests/E2E/takeover.py

The test ops simulate pressing Take Control / Give Back in the mirror window.
"""
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "clients", "python"))
from driver import Driver  # noqa: E402

d = Driver()
results = []


def check(label, cond, detail=""):
    results.append(bool(cond))
    print(f"[{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail and not cond else ""))


def call(name, timeout_ms=None, **arguments):
    req = {"name": name, "arguments": arguments}
    if timeout_ms:
        req["timeout_ms"] = timeout_ms
    return d.call(req)


def text_area_ref(win):
    def find(n):
        if n.get("role") == "AXTextArea":
            return n
        for c in n.get("children", []):
            f = find(c)
            if f:
                return f
    return find(call("computer_snapshot", window=win)["result"]["tree"])


def main():
    if not d._test_control(False).get("ok"):
        sys.exit("Launch the host with: open build/MacDriver.app --args --test-ops")

    r = call("computer_open", app="TextEdit", intent="new_document")
    win = next(w["window"] for w in r["result"]["windows"] if w["status"] == "created")
    call("computer_click", ref=text_area_ref(win)["ref"])

    def caret(w):
        return (text_area_ref(w).get("selection") or {}).get("location")

    # 1. Takeover pauses an in-flight action; Give Back resumes it, exactly once.
    out = {}
    t = threading.Thread(target=lambda: out.update(call("computer_type", text="a" * 4000)))
    t.start()
    time.sleep(0.5)
    d._test_control(True)
    time.sleep(0.6)
    n1 = caret(win)
    time.sleep(0.6)
    n2 = caret(win)
    check("takeover pauses typing midway", t.is_alive() and n1 is not None and 0 < n1 < 4000, n1)
    check("nothing is typed while paused", n1 == n2, (n1, n2))
    st = d.status()["result"]
    check("takeover: control owned by user", st["control"] == "user")
    check("takeover: no keys or buttons left held", st["held_inputs"] == 0)
    d._test_control(False)
    t.join()
    check("typing resumes after Give Back and completes", out.get("ok") and out["result"]["characters"] == 4000, out.get("error"))
    check("resumed call reports the pause", out.get("paused_ms", 0) >= 1000 and any("Paused" in w for w in out.get("warnings", []))
          and "resumed_after_takeover" in out["effect"]["evidence"], (out.get("paused_ms"), out.get("warnings")))
    check("every character typed exactly once", caret(win) == 4000, caret(win))

    # 1b. If the user moves the caret while in control, the paused call does not continue elsewhere.
    def find_role(n, role):
        if n.get("role") == role:
            return n
        for c in n.get("children", []):
            f = find_role(c, role)
            if f:
                return f
    # The visible part of the document (the text area itself extends above it once scrolled).
    area = find_role(call("computer_snapshot", window=win)["result"]["tree"], "AXScrollArea")["frame"]
    out = {}
    t = threading.Thread(target=lambda: out.update(call("computer_type", text="b" * 3000)))
    t.start()
    time.sleep(0.4)
    d._test_control(True)
    time.sleep(0.5)
    d._round_trip({"op": "test_user_input", "kind": "click", "x": area["x"] + 100, "y": area["y"] + 60}, 10)
    time.sleep(0.3)
    d._test_control(False)
    t.join()
    check("paused typing stops when the user moved the caret", not out["ok"] and out["error"]["code"] == "target_changed" and out["dispatch"] == "partial", out.get("error") or out.get("result"))
    check("stopped call reports how much was typed", any("Typed" in w for w in out["warnings"]), out["warnings"])
    call("computer_click", ref=text_area_ref(win)["ref"])

    # 1c. A takeover in the middle of a held gesture (drag) releases it and does not resume it.
    r = call("computer_window", window=win, state="normal", frame={"x": 100, "y": 100, "width": 600, "height": 400})
    shot = call("computer_screenshot")["result"]
    s = shot["scale"]
    out = {}
    path = [{"x": (100 + 300) * s, "y": (100 + 12) * s}, {"x": (100 + 300 + 700) * s, "y": (100 + 12 + 300) * s}]
    t = threading.Thread(target=lambda: out.update(call("computer_drag", **{"in": shot["screenshot"]}, path=path)))
    t.start()
    time.sleep(0.35)
    d._test_control(True)
    t.join(timeout=5)
    check("takeover mid-drag ends the gesture instead of resuming it", not t.is_alive() and not out.get("ok", True)
          and out["error"]["code"] == "user_has_control" and out["error"].get("details", {}).get("resumable") is False and out["dispatch"] == "partial", out.get("error") or out)
    check("mid-drag takeover leaves no button held", d.status()["result"]["held_inputs"] == 0)

    # 2. While the user has control, mutating calls pause and then fail without side effects.
    t0 = time.time()
    r = call("computer_key", key="Return", timeout_ms=1200)
    check("paused call fails after its timeout with user_has_control", r["error"]["code"] == "user_has_control" and r["dispatch"] == "none", r.get("error"))
    check("paused call actually waited", time.time() - t0 >= 1.0)
    r = call("computer_screenshot")
    check("observation tools still work during takeover", r["ok"])

    # 3. A paused call resumes only after an explicit Give Back.
    out = {}
    t = threading.Thread(target=lambda: out.update(call("computer_click", timeout_ms=15000, ref=text_area_ref(win)["ref"])))
    t.start()
    time.sleep(1.0)
    check("call still paused before Give Back", t.is_alive())
    d._test_control(False)
    t.join()
    check("paused call resumes after Give Back", out.get("ok"), out.get("error"))
    check("call that waited to start reports the pause", any("Paused" in w for w in out.get("warnings", [])), out.get("warnings"))

    # 4. Input location from before the takeover is not trusted afterwards.
    d._test_control(True)
    d._test_control(False)
    r = call("computer_type", text="x")
    check("takeover invalidates the previous input location", r["error"]["code"] == "no_input_target", r.get("error"))

    # 5. While in control, the user's input in the mirror reaches background apps.
    # Use a fresh document so the checks are not confused by earlier text.
    r = call("computer_open", app="TextEdit", intent="new_document")
    doc2 = next(w["window"] for w in r["result"]["windows"] if w["status"] == "created")
    ta = text_area_ref(doc2)
    f = ta["frame"]
    cx, cy = f["x"] + f["width"] / 2, f["y"] + min(40, f["height"] / 2)
    d._test_control(True)
    before = ta.get("value", "")
    r = d._round_trip({"op": "test_user_input", "kind": "click", "x": cx, "y": cy}, 10)
    check("mirror click accepted", r.get("ok"), r)
    for code in (0x04, 0x22):  # "h", "i"
        d._round_trip({"op": "test_user_input", "kind": "key", "code": code}, 10)
    time.sleep(0.4)
    after = text_area_ref(doc2).get("value", "")
    check("mirror click + keys type into the background app", after == "hi", repr(after))
    d._round_trip({"op": "test_user_input", "kind": "click", "x": f["x"] + 8, "y": f["y"] + 6, "count": 2}, 10)
    time.sleep(0.2)
    sel = text_area_ref(doc2).get("selection")
    check("mirror double-click selects the word", sel == {"location": 0, "length": 2}, sel)
    d._round_trip({"op": "test_user_input", "kind": "click", "x": f["x"] + 6, "y": f["y"] + 6}, 10)
    time.sleep(0.2)
    sel = text_area_ref(doc2).get("selection")
    check("mirror click places the caret", sel == {"location": 0, "length": 0}, sel)
    d._round_trip({"op": "test_user_input", "kind": "drag", "x": f["x"] + 6, "y": f["y"] + 6, "x2": f["x"] + 60, "y2": f["y"] + 6}, 10)
    time.sleep(0.2)
    sel = text_area_ref(doc2).get("selection")
    check("mirror drag selects text", sel == {"location": 0, "length": 2}, sel)
    d._round_trip({"op": "test_user_input", "kind": "click", "x": f["x"] + 200, "y": f["y"] + 200}, 10)  # caret to the end
    for _ in range(40):  # make the document scrollable: Return key presses
        d._round_trip({"op": "test_user_input", "kind": "key", "code": 0x24}, 10)
    time.sleep(0.3)
    def vpos():
        def find(n):
            fr = n.get("frame") or {}
            # The vertical bar is the tall one; the horizontal bar comes first in the tree.
            if n.get("role") == "AXScrollBar" and n.get("value") is not None and fr.get("height", 0) > fr.get("width", 0):
                return n
            for c in n.get("children", []):
                x = find(c)
                if x:
                    return x
        sb = find(call("computer_snapshot", window=doc2)["result"]["tree"])
        return sb["value"] if sb else None
    p0 = vpos()
    d._round_trip({"op": "test_user_input", "kind": "scroll", "x": cx, "y": cy + 60, "dy": 10}, 10)
    time.sleep(0.4)
    p1 = vpos()
    check("mirror scroll moves the content", p0 is not None and p1 is not None and p1 != p0, f"{p0} -> {p1}")
    d._test_control(False)
    check("no inputs left held after mirror input", d.status()["result"]["held_inputs"] == 0)

    # Cleanup: discard the test drafts explicitly.
    for w in (win, doc2):
        r = call("computer_close", window=w)
        if r["ok"] and r["result"]["status"] == "prompt_pending":
            ref = next((b["ref"] for b in r["result"]["prompt"]["buttons"] if (b.get("name") or "").lower() in ("delete", "don't save", "don’t save")), None)
            if ref:
                call("computer_click", ref=ref)

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
