#!/usr/bin/env python3
"""Task 2: go to Amazon, find a pair of smart glasses, add it to the shopping cart. Nothing is bought."""
import urllib.parse
from common import call, find, finish, goto, name_of, open_window, parser, run, stop_if_bot_check, title, wait_for


def main():
    p = parser(__doc__)
    p.add_argument("--search", default="smart glasses", help="what to search for (default: smart glasses)")
    args = p.parse_args()
    window = open_window(args.browser)
    goto(window, "https://www.amazon.com/s?k=" + urllib.parse.quote_plus(args.search))

    def product_links():
        # Product titles: one-or-two-line links below the header, not the page's navigation.
        links = find(window, "glasses" if "glasses" in args.search.lower() else args.search.split()[0], role="AXLink")
        return [l for l in links if l["frame"]["y"] > 250 and l["frame"]["height"] < 60 and len(name_of(l)) > 30]

    links = wait_for("search results", lambda: stop_if_bot_check(window) or product_links())
    product = links[0]
    print(f"Opening: {name_of(product)[:100]}")
    results_title = title(window)
    call("computer_click", ref=product["ref"])
    wait_for("the product page", lambda: title(window) != results_title)
    stop_if_bot_check(window)

    def add_button():
        return [b for b in find(window, "Add to cart", role="AXButton") if name_of(b).lower() == "add to cart" and b["frame"]["width"] > 20]

    button = wait_for("the Add to cart button", add_button)[0]
    if args.dry_run:
        print("Dry run: not clicking Add to cart.")
    else:
        call("computer_click", ref=button["ref"])
        wait_for("the cart to confirm", lambda: find(window, "Added to cart"), timeout=15)
        count = [name_of(m) for m in find(window, "in cart")]
        print("Added to cart." + (f" Amazon says: {count[0]}" if count else ""))
    finish(window, args)


run(main)
