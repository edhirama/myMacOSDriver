#!/usr/bin/env python3
"""Task 3: open Gmail, list the three most recent unread messages, and draft a reply to the latest
without sending it.

A script cannot write a summary by itself: it prints each message's sender, subject, time and
preview line for an agent (or you) to summarize, and types the reply text you pass with --reply."""
from common import TaskError, call, find, finish, goto, name_of, open_window, parser, run, title, wait_for

DEFAULT_REPLY = "Thanks for your message. I'll take a look and get back to you soon."


def main():
    p = parser(__doc__)
    p.add_argument("--reply", default=DEFAULT_REPLY, help="text of the draft reply")
    args = p.parse_args()
    window = open_window(args.browser)
    goto(window, "https://mail.google.com/mail/u/0/#inbox")

    def unread_rows():
        return [r for r in find(window, "unread", role="AXRow") if name_of(r).lower().startswith("unread")]

    rows = wait_for("the inbox", unread_rows, timeout=30)[:3]
    print("Three most recent unread messages:")
    for i, row in enumerate(rows, 1):
        # A row reads "unread, <sender> , <subject> , <time> , <preview>".
        parts = [part.strip() for part in name_of(row).split(" , ")]
        sender = parts[0].split(",", 1)[-1].strip()
        subject, when = (parts[1:] + ["", ""])[:2]
        print(f"  {i}. {sender} | {subject} | {when}\n     {' '.join(parts[3:])[:240]}")
    if args.dry_run:
        print("Dry run: not opening the latest message (that would mark it read) and not drafting.")
        return finish(window, args)

    inbox_title = title(window)
    call("computer_click", ref=rows[0]["ref"])
    wait_for("the message to open", lambda: title(window) != inbox_title)
    reply = wait_for("the Reply button", lambda: [b for b in find(window, "Reply", role="AXButton") if name_of(b) in ("Reply", "Responder")])[0]
    call("computer_click", ref=reply["ref"])
    body = wait_for("the reply box", lambda: find(window, "Message Body", role="AXTextArea") or find(window, "Corpo da mensagem", role="AXTextArea"))[0]
    call("computer_click", ref=body["ref"])
    call("computer_type", text=args.reply)
    typed = (find(window, "Message Body", role="AXTextArea") or find(window, "Corpo da mensagem", role="AXTextArea"))[0]
    if args.reply[:20] not in str(typed.get("value") or ""):
        raise TaskError("The reply text did not appear in the reply box")
    print("Draft typed and left unsent. Gmail saves it to Drafts on its own.")
    finish(window, args)


run(main)
