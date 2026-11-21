"""Shared helpers for the example tasks. Everything goes through driver.call(request)."""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "clients", "python"))
from driver import Driver  # noqa: E402

driver = Driver()


class TaskError(Exception):
    """The task cannot continue; the message says why and what to do."""


def call(name, **arguments):
    """One driver call. Prints warnings; raises TaskError when the driver reports an error."""
    response = driver.call({"name": name, "arguments": arguments})
    for warning in response.get("warnings", []):
        # Searches already narrow the snapshot; the hint to narrow it is not news here.
        if name == "computer_snapshot" and "more elements than a snapshot holds" in warning:
            continue
        print(f"  note ({name}): {warning}")
    if not response.get("ok"):
        error = response.get("error", {})
        raise TaskError(f"{name} failed: {error.get('code')}: {error.get('message')}")
    return response["result"]


def parser(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--browser", default="Google Chrome", help="browser app to drive (default: Google Chrome)")
    p.add_argument("--dry-run", action="store_true", help="stop before the step that changes anything in your account")
    p.add_argument("--close", action="store_true", help="close the browser window when the task ends")
    return p


def open_window(browser):
    """Opens a new browser window on the virtual monitor and returns its id."""
    result = call("computer_open", app=browser, intent="new_window")
    created = [w for w in result["windows"] if w["status"] == "created"]
    if not created:
        raise TaskError(f"{browser} did not open a new window")
    return created[0]["window"]


def find(window, text, role=None, visible=True):
    """Elements in the window whose name or value contains `text`, top to bottom."""
    arguments = {"window": window, "query": text}
    if visible:
        arguments["scope"] = "visible"
    matches = call("computer_snapshot", **arguments)["matches"]
    if role:
        matches = [m for m in matches if m["role"] == role]
    return sorted(matches, key=lambda m: (m.get("frame", {}).get("y", 0), m.get("frame", {}).get("x", 0)))


def name_of(element):
    return (element.get("name") or str(element.get("value") or "")).replace("\n", " ").strip()


def wait_for(what, check, timeout=20, interval=0.7):
    """Polls `check()` until it returns something truthy; raises TaskError after `timeout` seconds."""
    deadline = time.time() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.time() > deadline:
            raise TaskError(f"Timed out waiting for {what}")
        time.sleep(interval)


def title(window):
    # A query that matches nothing keeps the answer small; only the title is wanted.
    return call("computer_snapshot", window=window, query="~no-such-element~")["title"] or ""


def goto(window, url):
    """Types `url` into the window's address bar and presses Return."""
    bars = [m for m in find(window, "Address and search bar", role="AXTextField")]
    if not bars:
        raise TaskError("Could not find the browser's address bar")
    call("computer_click", ref=bars[0]["ref"])
    call("computer_key", key="super+a")
    call("computer_type", text=url + "\n")


def scroll(window, direction="down", amount=6):
    shot = call("computer_screenshot", window=window)
    call("computer_scroll", **{"in": shot["screenshot"]}, x=shot["width"] // 2, y=shot["height"] // 2,
         direction=direction, amount=amount)
    time.sleep(0.8)


BOT_CHECKS = ("I am human", "Check the box to continue", "Press & Hold", "confirm you are a human", "Verify you are human")


def stop_if_bot_check(window):
    """Sites sometimes ask to confirm a human is present. That is for the person to answer, never the script."""
    for phrase in BOT_CHECKS:
        if find(window, phrase):
            raise TaskError(f'The site is asking to confirm you are human ("{phrase}"). Answer it yourself in the mirror '
                            "(Take Control), then run the task again.")


def run(main):
    """Runs a task's main(args) and turns TaskError into a clean exit."""
    try:
        main()
    except TaskError as e:
        print(f"STOPPED: {e}")
        sys.exit(1)


def finish(window, args):
    if args.close:
        call("computer_close", window=window)
    else:
        print(f"The window ({window}) is left open on the virtual monitor.")
