#!/usr/bin/env python3
"""End-to-end test against a running MacDriver host, using TextEdit and a temporary document.

    python3 tests/e2e.py

The script only creates and edits its own temporary file. It exercises all 11 tools, the main
error paths, idempotent retries and cancellation, and checks that the user's frontmost app,
held inputs and display arrangement are unchanged at the end.
"""
import json
import os
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "clients", "python"))
from driver import Driver  # noqa: E402

d = Driver()
results = []


def call(name, **arguments):
    req = {"name": name, "arguments": arguments}
    if "_id" in arguments:
        req["id"] = arguments.pop("_id")
    return d.call(req)


def check(label, cond, detail=""):
    results.append((label, bool(cond)))
    mark = "PASS" if cond else "FAIL"
    print(f"[{mark}] {label}" + (f" — {detail}" if detail and not cond else ""))
    return cond


def find(node, pred):
    if pred(node):
        return node
    for c in node.get("children", []):
        f = find(c, pred)
        if f:
            return f
    return None


def text_area(window):
    snap = call("computer_snapshot", window=window)
    assert snap["ok"], snap
    return find(snap["result"]["tree"], lambda n: n.get("role") == "AXTextArea")


def main():
    status = d.status()["result"]
    if not all(status["permissions"].values()):
        sys.exit(f"Grant permissions first: {status['permissions']}")
    frontmost_before = call("computer_apps")["result"]["system_frontmost_app"]

    tmpdir = tempfile.mkdtemp(prefix="macdriver-e2e-")
    path = os.path.join(tmpdir, "e2e.txt")
    with open(path, "w") as f:
        f.write("first line\n")

    # --- open -------------------------------------------------------------
    r = call("computer_open", app="TextEdit", path=path)
    check("open: ok", r["ok"], r.get("error"))
    wins = r["result"]["windows"]
    created = [w for w in wins if w["status"] == "created"]
    check("open: created a window on the target", created and created[0]["placement"] in ("moved_to_target", "already_on_target"), wins)
    win = created[0]["window"]

    # --- apps -------------------------------------------------------------
    r = call("computer_apps")
    listed = [w for a in r["result"]["apps"] for w in a["windows"]]
    check("apps: window listed with title and frame", any(w["window"] == win and w["frame"]["width"] > 0 for w in listed))

    # --- screenshot ---------------------------------------------------------
    shot = call("computer_screenshot", **{"return": "path"})
    check("screenshot: display capture", shot["ok"] and shot["result"]["width"] == status["targets"][0]["size"]["width"])
    wshot = call("computer_screenshot", window=win, **{"return": "path"})
    check("screenshot: window capture has origin", wshot["ok"] and "origin" in wshot["result"])

    # --- snapshot + click by ref + type -------------------------------------
    ta = text_area(win)
    check("snapshot: text area has ref and value", ta and ta.get("ref") and "first line" in ta.get("value", ""))
    r = call("computer_click", ref=ta["ref"])
    check("click(ref): ok", r["ok"], r.get("error"))
    r = call("computer_key", key="super+ArrowDown")
    check("key: super+ArrowDown ok", r["ok"], r.get("error"))
    r = call("computer_type", text="typed by e2e\nsecond typed line")
    check("type: dispatched and confirmed", r["ok"] and r["dispatch"] == "dispatched" and r["effect"]["confirmed"], r)
    val = text_area(win)["value"]
    # TextEdit may auto-capitalize sentence starts (an app feature a human would see too).
    check("type: text appended at end", val.startswith("first line") and val.rstrip().lower().endswith("second typed line"), repr(val))

    # --- idempotent retry ----------------------------------------------------
    rid = "e2e-retry-" + str(time.time())
    a = d.call({"id": rid, "name": "computer_type", "arguments": {"text": " [once]"}})
    b = d.call({"id": rid, "name": "computer_type", "arguments": {"text": " [once]"}})
    val = text_area(win)["value"]
    check("retry: same id executes once", a["ok"] and b["replayed"] and val.count("[once]") == 1, repr(val))
    c = d.call({"id": rid, "name": "computer_type", "arguments": {"text": "different"}})
    check("retry: id reuse with different args rejected", c["error"]["code"] == "id_conflict")

    # --- click by screenshot coordinates -------------------------------------
    shot = call("computer_screenshot")["result"]
    r = call("computer_apps")
    frame = next(w["frame"] for a in r["result"]["apps"] for w in a["windows"] if w["window"] == win)
    # Empty area near the bottom of the text view: caret goes to the end of the text.
    x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] - 40
    r = call("computer_click", **{"in": shot["screenshot"], "x": x * shot["scale"], "y": y * shot["scale"]})
    check("click(in,x,y): ok", r["ok"] and r["result"]["window"] == win, r)
    call("computer_type", text="!")
    check("click(in,x,y): click below the text puts the caret at the end", text_area(win)["value"].rstrip().endswith("!"))
    # Caret placement must really follow the click: caret is at the end, click the very start.
    t = text_area(win)
    end = t["selection"]["location"]
    tf = t["frame"]
    r = call("computer_click", **{"in": shot["screenshot"], "x": (tf["x"] + 6) * shot["scale"], "y": (tf["y"] + 6) * shot["scale"]})
    sel = text_area(win)["selection"]
    check("click(in,x,y): caret moves to the clicked character", end > 0 and sel == {"location": 0, "length": 0}, (end, sel, r["result"].get("method")))
    r = call("computer_click", **{"in": shot["screenshot"], "x": (tf["x"] + 14) * shot["scale"], "y": (tf["y"] + 6) * shot["scale"]}, count=2)
    sel = text_area(win)["selection"]
    check("click(in,x,y) count=2: selects the word 'first'", sel == {"location": 0, "length": 5}, sel)
    r = call("computer_drag", **{"in": shot["screenshot"]}, path=[{"x": (tf["x"] + 6) * shot["scale"], "y": (tf["y"] + 6) * shot["scale"]},
                                                                   {"x": (tf["x"] + 6) * shot["scale"], "y": (tf["y"] + 20) * shot["scale"]}])
    sel = text_area(win)["selection"]
    check("drag over text selects it", r["ok"] and sel["location"] == 0 and sel["length"] >= 10, (sel, r["result"].get("method")))
    call("computer_click", **{"in": shot["screenshot"], "x": x * shot["scale"], "y": y * shot["scale"]})  # back to the end

    # --- scroll ---------------------------------------------------------------
    call("computer_type", text="\n" + "\n".join(f"filler {i}" for i in range(80)))
    shot = call("computer_screenshot")["result"]
    r = call("computer_scroll", **{"in": shot["screenshot"], "x": x * shot["scale"], "y": (frame["y"] + 150) * shot["scale"]},
             direction="up", amount=15)
    check("scroll: dispatched with visible effect", r["ok"] and r["effect"]["confirmed"], r)

    # --- window states --------------------------------------------------------
    r = call("computer_window", window=win, state="maximized")
    check("window: maximized", r["ok"] and r["result"]["state"] == "maximized", r)
    r = call("computer_window", window=win, state="normal")
    check("window: normal restores frame", r["ok"] and r["result"]["state"] == "normal" and abs(r["result"]["frame"]["width"] - frame["width"]) <= 2, r)
    r = call("computer_window", window=win, frame={"x": 200, "y": 150, "width": 700, "height": 500})
    check("window: frame applied and read back", r["ok"] and r["result"]["frame"]["x"] == 200 and r["result"]["frame"]["width"] == 700, r)
    r = call("computer_window", window=win, state="minimized")
    check("window: minimized", r["ok"] and r["result"]["state"] == "minimized", r)
    r = call("computer_type", text="x")
    check("type into minimized window rejected", not r["ok"] and r["error"]["code"] == "no_input_target", r)
    r = call("computer_window", window=win, state="normal")
    check("window: restored from minimized", r["ok"] and r["result"]["state"] == "normal", r)

    # --- drag window by title bar --------------------------------------------
    shot = call("computer_screenshot")["result"]
    s = shot["scale"]
    path_pts = [{"x": (200 + 350) * s, "y": (150 + 12) * s}, {"x": (200 + 450) * s, "y": (150 + 72) * s}]
    r = call("computer_drag", **{"in": shot["screenshot"]}, path=path_pts)
    f = r.get("result", {}).get("window_frame", {})
    check("drag: title bar moves window", r["ok"] and abs(f.get("x", 0) - 300) <= 3 and abs(f.get("y", 0) - 210) <= 3, r)

    # --- cancellation ----------------------------------------------------------
    call("computer_click", ref=text_area(win)["ref"])
    rid = "e2e-cancel-" + str(time.time())
    out = {}
    t = threading.Thread(target=lambda: out.update(d.call({"id": rid, "name": "computer_type", "arguments": {"text": "z" * 3000}})))
    t.start()
    time.sleep(0.6)
    d.cancel(rid)
    t.join()
    r = out
    check("cancel: stopped with partial dispatch", not r["ok"] and r["error"]["code"] == "cancelled" and r["dispatch"] == "partial", r.get("error"))
    check("cancel: nothing left pressed", d.status()["result"]["held_inputs"] == 0)

    # --- validation errors -----------------------------------------------------
    errs = {
        "mixed position forms": (call("computer_click", ref="ref:1.1", **{"in": "x", "x": 1, "y": 1}), "invalid_argument"),
        "unknown screenshot": (call("computer_click", **{"in": "shot:nope.1", "x": 1, "y": 1}), "unknown_screenshot"),
        "out of bounds": (call("computer_click", **{"in": shot["screenshot"], "x": 99999, "y": 5}), "out_of_bounds"),
        "unknown window": (call("computer_window", window="win:1", state="normal"), "unknown_window"),
        "stale ref": (call("computer_click", ref="ref:999999.1"), "stale_ref"),
        "intent with path": (call("computer_open", app="TextEdit", path=path, intent="new_window"), "invalid_argument"),
        "unknown target": (call("computer_apps", computer="display:4242"), "unknown_target"),
        "bad key": (call("computer_key", key="hyper+q"), "invalid_argument"),
    }
    for label, (r, code) in errs.items():
        check(f"error: {label} -> {code}", not r["ok"] and r["error"]["code"] == code and r["dispatch"] == "none", r.get("error"))

    # --- close a document backed by a file ------------------------------------
    # With macOS autosave, edits to a saved file are written on close without a prompt.
    r = call("computer_close", window=win)
    check("close: file-backed doc closes (autosaved, nothing discarded)", r["ok"] and r["result"]["status"] == "closed", r)
    time.sleep(0.5)
    with open(path) as fh:
        saved = fh.read()
    check("close: content preserved on disk", "typed by e2e" in saved.lower() and "[once]" in saved)

    # --- open intent + close with unsaved content -------------------------------
    r = call("computer_open", app="TextEdit", intent="new_document")
    new = [w for w in r.get("result", {}).get("windows", []) if w["status"] == "created"]
    check("open intent=new_document: new window on target", r["ok"] and new and new[0]["placement"] in ("moved_to_target", "already_on_target"), r)
    if new:
        doc = new[0]["window"]
        call("computer_click", ref=text_area(doc)["ref"])
        call("computer_type", text="unsaved draft")
        r = call("computer_close", window=doc)
        check("close: untitled doc with content leaves prompt", r["ok"] and r["result"]["status"] == "prompt_pending", r)
        if r["ok"] and r["result"]["status"] == "prompt_pending":
            buttons = {(b.get("name") or "").lower(): b["ref"] for b in r["result"]["prompt"]["buttons"]}
            check("close: prompt exposes its buttons as refs", "cancel" in buttons, list(buttons))
            if "cancel" in buttons:
                call("computer_click", ref=buttons["cancel"])
                still = any(w["window"] == doc for a in call("computer_apps")["result"]["apps"] for w in a["windows"])
                check("close: Cancel keeps the window and its content", still and "unsaved draft" in text_area(doc)["value"])
            # The script, not the driver, decides to discard this test draft.
            r = call("computer_close", window=doc)
            prompt_buttons = r.get("result", {}).get("prompt", {}).get("buttons", []) if r["ok"] else []
            discard = next((b["ref"] for b in prompt_buttons
                            if (b.get("name") or "").lower() in ("delete", "don’t save", "don't save")), None)
            if discard:
                call("computer_click", ref=discard)
                gone = not any(w["window"] == doc for a in call("computer_apps")["result"]["apps"] for w in a["windows"])
                check("close: explicit discard by the script closes it", gone)

    # --- invariants -------------------------------------------------------------
    st = d.status()["result"]
    check("invariant: no held inputs", st["held_inputs"] == 0)
    check("invariant: physical arrangement unchanged", st["arrangement_deviations"] == [], st["arrangement_deviations"])
    frontmost_after = call("computer_apps")["result"]["system_frontmost_app"]
    check("invariant: frontmost app unchanged (unless you switched apps)", frontmost_after == frontmost_before,
          f"{frontmost_before} -> {frontmost_after}")

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
