#!/usr/bin/env python3
"""Task 1: open a new browser window on the virtual monitor, go to the X feed, like the first post."""
import re
from common import TaskError, call, find, finish, goto, name_of, open_window, parser, run, wait_for


def main():
    args = parser(__doc__).parse_args()
    window = open_window(args.browser)
    goto(window, "https://x.com/home")

    def like_buttons():
        # "47 Likes. Like" before, "48 Likes. Liked" after.
        return [b for b in find(window, "Like", role="AXButton") if re.search(r"Likes?\. Liked?$|^Liked?$", name_of(b))]

    try:
        buttons = wait_for("the feed", like_buttons)
    except TaskError:
        if find(window, "Email or username") or find(window, "Sign in"):
            raise TaskError("X is signed out in this browser. Sign in, then run the task again.")
        raise
    first = buttons[0]
    print(f"First post: {name_of(first)}")
    if name_of(first).endswith("Liked"):
        print("It is already liked; nothing to do.")
    elif args.dry_run:
        print("Dry run: not clicking Like.")
    else:
        call("computer_click", ref=first["ref"])
        after = wait_for("the like to register", lambda: [b for b in like_buttons() if name_of(b).endswith("Liked")], timeout=8)
        print(f"Liked: {name_of(after[0])}")
    finish(window, args)


run(main)
