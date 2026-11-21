#!/usr/bin/env python3
"""Task 4: open iFood (Uber Eats does not operate in Brazil) and find three nearby options with an
estimated delivery time under 30 minutes.

iFood needs a delivery address. If none is set, the script uses the browser's location, which makes
the browser ask for permission: pass --allow-location to have the script choose "Allow this time",
or answer the prompt yourself in the mirror."""
import re
import time
from common import TaskError, call, find, finish, goto, name_of, open_window, parser, run, scroll, stop_if_bot_check, wait_for

CARD = re.compile(r"Entrega entre (\d+) e (\d+) minutos")


def main():
    p = parser(__doc__)
    p.add_argument("--allow-location", action="store_true", help='choose "Allow this time" on the browser\'s location prompt')
    p.add_argument("--max-minutes", type=int, default=30, help="upper delivery estimate must be below this (default: 30)")
    p.add_argument("--count", type=int, default=3, help="how many options to find (default: 3)")
    args = p.parse_args()
    window = open_window(args.browser)
    goto(window, "https://www.ifood.com.br/restaurantes")

    def cards():
        return [b for b in find(window, "Entrega entre", role="AXButton") if CARD.search(name_of(b))]

    def location_button():
        return find(window, "Usar minha localização", role="AXButton")

    def listing():
        # With an address set, the page opens on its categories; the restaurant cards are further down.
        return cards() or find(window, "Conheça as categorias") or find(window, "Lanches", role="AXLink")

    wait_for("iFood to load", lambda: stop_if_bot_check(window) or location_button() or listing(), timeout=30)
    if location_button():
        call("computer_click", ref=location_button()[0]["ref"])
        time.sleep(2.5)
        # The permission prompt is the browser's own bubble, not part of the page.
        prompt = call("computer_snapshot", query="Allow this time")["matches"]
        if prompt:
            if not args.allow_location:
                raise TaskError("The browser is asking to share your location with iFood. Answer it in the mirror (Take Control), "
                                "or run again with --allow-location.")
            call("computer_click", ref=prompt[0]["ref"])
            time.sleep(1.5)
        if location_button():
            call("computer_click", ref=location_button()[0]["ref"])
        wait_for("restaurants near you", lambda: stop_if_bot_check(window) or (not location_button() and listing()), timeout=30)

    seen = {}
    def collect():
        for card in cards():
            text = name_of(card)
            low, high = map(int, CARD.search(text).groups())
            seen[text.split(". Nota")[0]] = (high, low, text)
        return [v for v in seen.values() if v[0] < args.max_minutes]

    # Walk the list: load more while the page offers it, otherwise scroll on.
    for _ in range(40):
        stop_if_bot_check(window)
        if len(collect()) >= args.count + 2:
            break
        more = [b for b in find(window, "Ver mais", role="AXButton") if b["frame"]["y"] > 250]
        if more:
            call("computer_click", ref=more[-1]["ref"])
            time.sleep(2.5)
        else:
            scroll(window, "down", 8)
    fast = sorted(collect())
    print(f"{len(seen)} places seen, {len(fast)} with delivery under {args.max_minutes} minutes:")
    for high, low, text in fast[:max(args.count, 3)]:
        print(f"  {low}-{high} min | {text}")
    if len(fast) < args.count:
        print(f"Fewer than {args.count} qualify right now. Fastest of the rest:")
        for high, low, text in sorted(v for v in seen.values() if v[0] >= args.max_minutes)[:3]:
            print(f"  {low}-{high} min | {text.split('. Nota')[0]}")
    finish(window, args)


run(main)
