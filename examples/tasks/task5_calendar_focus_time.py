#!/usr/bin/env python3
"""Task 5: open Google Calendar on the virtual monitor and create a 30-minute event called
"Focus time" for tomorrow at 3 PM. Does nothing if the event is already there."""
import datetime
import time
import urllib.parse
from common import TaskError, call, find, finish, goto, name_of, open_window, parser, run, wait_for


def main():
    p = parser(__doc__)
    p.add_argument("--title", default="Focus time")
    p.add_argument("--hour", type=int, default=15, help="start hour, 24-hour clock (default: 15)")
    p.add_argument("--minutes", type=int, default=30, help="length in minutes (default: 30)")
    args = p.parse_args()
    day = datetime.date.today() + datetime.timedelta(days=1)
    start = datetime.datetime.combine(day, datetime.time(args.hour, 0))
    end = start + datetime.timedelta(minutes=args.minutes)
    day_view = f"https://calendar.google.com/calendar/u/0/r/day/{day.year}/{day.month}/{day.day}"

    def events():
        # Event chips read like "3pm - 3:30pm, Focus time, <calendar>, ..."
        # The whole day is searched, not only the hours scrolled into view.
        return [b for b in find(window, args.title, role="AXButton", visible=False) if f", {args.title}," in name_of(b)]

    def day_loaded():
        return find(window, str(day.year)) or find(window, "Create") or find(window, "Criar")

    window = open_window(args.browser)
    goto(window, day_view)
    wait_for("the calendar", day_loaded, timeout=30)
    # The page appears before its events do. Give them time to be drawn before concluding there are none:
    # deciding too early creates the event a second time.
    existing = []
    for _ in range(8):
        existing = events()
        if existing:
            break
        time.sleep(1)
    if existing:
        print(f"Already on the calendar: {name_of(existing[0])}")
        return finish(window, args)
    if args.dry_run:
        print(f"Dry run: would create '{args.title}' on {day:%d %b %Y}, {start:%H:%M}-{end:%H:%M}.")
        return finish(window, args)

    fmt = "%Y%m%dT%H%M%S"
    goto(window, "https://calendar.google.com/calendar/u/0/r/eventedit?text=" + urllib.parse.quote_plus(args.title)
         + f"&dates={start.strftime(fmt)}/{end.strftime(fmt)}")
    save = wait_for("the event form", lambda: [b for b in find(window, "Sa", role="AXButton") if name_of(b) in ("Save", "Salvar")], timeout=30)[0]
    if not [f for f in find(window, args.title, role="AXTextField")]:
        raise TaskError("The event form did not show the title; not saving")
    call("computer_click", ref=save["ref"])
    wait_for("the event to be saved", lambda: not [b for b in find(window, "Sa", role="AXButton") if name_of(b) in ("Save", "Salvar")], timeout=20)
    goto(window, day_view)
    created = wait_for("the event to appear", events, timeout=30)
    print(f"Created: {name_of(created[0])}")
    finish(window, args)


run(main)
