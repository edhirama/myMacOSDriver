# MacDriver

A local macOS app with two parts:

- **Virtual Monitor**: a real, macOS-recognized virtual display with a live mirror preview and **Take Control / Give Back**.
- **Driver**: a single scriptable entry point, `driver.call(request)`, that implements 11 `computer_*` tools against real application windows on that display.

Scripts drive apps in the background. The user's mouse, keyboard, focus and display arrangement are never touched. When the user takes control, running script actions pause, and they continue where they stopped after Give Back.

```python
import sys; sys.path.insert(0, "clients/python")
from driver import driver

shot = driver.call({"name": "computer_screenshot", "arguments": {}})["result"]
driver.call({"name": "computer_open", "arguments": {"app": "TextEdit", "intent": "new_document"}})
driver.call({"name": "computer_click", "arguments": {"in": shot["screenshot"], "x": 300, "y": 200}})
driver.call({"name": "computer_type", "arguments": {"text": "Hello\n"}})
```

## Requirements

- macOS 14 or later (verified on macOS 26.2), Swift 6 toolchain (Xcode 16+). The package builds in Swift 6 language mode, so data-race safety is checked by the compiler.
- Permissions for **MacDriver.app**: Accessibility, and Screen & System Audio Recording.

## Build and run

```bash
scripts/bundle.sh
```

```bash
open build/MacDriver.app
```

```bash
build/driverctl status
```

MacDriver runs as a menu-bar app (display icon). The menu shows the state, the virtual display, the arrangement check and the permissions, and offers Show Mirror, Take Control / Give Back and Quit. The mirror window opens at launch; pass `--no-mirror` to start without it.

**From Xcode.** Opening `Package.swift` gives an auto-generated `MacDriverHost` scheme. Don't use it: it runs a bare executable from DerivedData that macOS treats as a different program, so it never has the permissions. Instead, install the scheme once:

```bash
scripts/install_xcode_scheme.sh
```

Then pick **MacDriver (app)** in Xcode. It builds normally, packages and signs `build/MacDriver.app` in a post-build step (log: `build/xcode-package.log`), and runs and debugs that bundle. Its launch arguments include `--test-ops` and `--no-mirror`, both off by default. Only one host runs at a time: a second instance refuses to start and creates no display.

**Signing.** macOS ties permission grants to the code signature. `bundle.sh` signs with a local certificate named **"MacDriver Dev"** when one exists; otherwise it signs ad-hoc. With an ad-hoc signature, grants reset on every rebuild. To avoid that, create a certificate once in Keychain Access → Certificate Assistant → Create a Certificate (Type: Code Signing), or set `MACDRIVER_SIGN_IDENTITY`.

## Calling the driver

| Client | Example |
|---|---|
| Python | `clients/python/driver.py`: `Driver().call({...})`, with safe retries (same id) |
| Swift | `Sources/DriverClient`: `try Driver().call(["name": "computer_apps", "arguments": [:]])`, with the same safe retries. Add the `DriverClient` product of this package as a dependency. |
| CLI | `build/driverctl call computer_apps '{}'`, `build/driverctl call '{"name":"computer_key","arguments":{"key":"super+a"}}'`, `build/driverctl tools` |
| Raw | One JSON object per line over the Unix socket `~/Library/Application Support/MacDriver/driver.sock` |

`driverctl tools` (or `Driver().tools()`) returns every tool with a JSON Schema of its arguments, in the shape agent frameworks expect for tool definitions.

The request and response contract, the error codes, coordinates and idempotency rules are in [docs/PROTOCOL.md](docs/PROTOCOL.md). Architecture and design decisions are in [docs/DESIGN.md](docs/DESIGN.md).

## Resource use and disruption

- **Idle:** about 0.3% of one CPU core and 27 MB. The mirror is captured only while it is visible, and nothing polls.
- **Working:** about 60 ms of CPU per call.
- **The user's desktop:** input goes to apps in the background, so the pointer, the frontmost app and the keyboard are left alone. The exceptions are measured and listed in [docs/DESIGN.md](docs/DESIGN.md#disruption-to-the-users-desktop); the largest is an app that activates itself (Chrome on a new window), which costs about 8 ms of focus.

## Web pages

Browsers work like any other app: open a window, click the address bar, type the address. For large pages, narrow `computer_snapshot` with `scope: "visible"`, `detail: "compact"` or `query: "text"`:

```python
win = driver.call({"name": "computer_open", "arguments": {"app": "Google Chrome", "intent": "new_window"}})["result"]["windows"][0]["window"]
bar = driver.call({"name": "computer_snapshot", "arguments": {"window": win, "query": "Address and search bar"}})["result"]["matches"][0]
driver.call({"name": "computer_click", "arguments": {"ref": bar["ref"]}})
driver.call({"name": "computer_type", "arguments": {"text": "https://example.com\n"}})
```

## Example tasks

Five everyday tasks, each a script that works only through `driver.call`:

```bash
scripts/run_tasks.sh
```

| Task | Script | What it does |
|---|---|---|
| 1 | `examples/tasks/task1_x_like_first_post.py` | Opens the X feed and likes the first post. |
| 2 | `examples/tasks/task2_amazon_add_to_cart.py` | Searches Amazon for smart glasses and adds the first result to the cart. Buys nothing. |
| 3 | `examples/tasks/task3_gmail_unread_and_draft.py` | Lists the three latest unread Gmail messages and drafts a reply to the latest, unsent. |
| 4 | `examples/tasks/task4_ifood_dinner_options.py` | Finds three places on iFood with delivery under 30 minutes (Uber Eats does not operate in Brazil). |
| 5 | `examples/tasks/task5_calendar_focus_time.py` | Creates a 30-minute "Focus time" event in Google Calendar for tomorrow at 3 PM, unless it exists. |

- `scripts/run_tasks.sh 2 5` runs only those tasks.
- `scripts/run_tasks.sh --swift 2 5` runs the same tasks written in Swift (`examples/swift/DriverTasks`, built as `build/drivertasks`). Both versions make the same driver calls.
- `--dry-run` stops before the step that changes anything in your account; `--close` closes the browser window afterwards; `--browser NAME` picks another browser.
- The tasks use the browser's existing sign-ins. A script stops with a message when a site is signed out, asks for a permission, or asks to confirm a human is present; none of those is answered for you.
- Tasks 1 and 2 act again on every run: another post is liked, another item goes into the cart.

## Tests

```bash
swift test
```

33 unit tests: the ledger and its on-disk journal, the arbiter, tool schemas and argument validation, key parsing, deadlines and protocol parsing. One of them fails if `docs/PROTOCOL.md` stops mentioning a tool or parameter.

The end-to-end suites drive real apps on the virtual monitor through the running host. Start it with test ops enabled first:

```bash
open build/MacDriver.app --args --test-ops
```

| Suite | Checks | What it covers |
|---|---|---|
| `python3 Tests/E2E/e2e.py` | 45 | All 11 tools against TextEdit, with an untitled document. |
| `python3 Tests/E2E/takeover.py` | 25 | Take Control / Give Back: pausing and resuming a running action, the cases that must not resume, and the user's input through the mirror. |
| `python3 Tests/E2E/fixture.py` | 25 | The fixture app: standard controls plus two custom-drawn views that only real mouse and key events can reach. Build it first with `scripts/package_fixture.sh`. |
| `python3 Tests/E2E/recovery.py` | 10 | Kills and relaunches the host, then checks that an interrupted request is not run again and a finished one is replayed. |

`--test-ops` enables socket commands that stand in for the user pressing Take Control / Give Back and acting in the mirror. A host started without it refuses them.

## Layout

| Path | Contents |
|---|---|
| `Sources/DriverProtocol` | Wire types: JSON value, request, response, error codes |
| `Sources/CPrivate` | Declarations for the private APIs (`CGVirtualDisplay`, `_AXUIElementGetWindow`), weakly linked |
| `Sources/DriverCore/Display` | Virtual display, arrangement guard, pointer barrier |
| `Sources/DriverCore/Capture` | ScreenCaptureKit screenshots, change detection, mirror stream |
| `Sources/DriverCore/AX` | Accessibility wrappers, windows, snapshots and refs, menu commands |
| `Sources/DriverCore/Input` | Input router (one delivery path for scripts and the mirror), per-process event posting, input ledger, key-window focusing |
| `Sources/DriverCore/Core` | `Driver` (the `call` pipeline), idempotency ledger and journal, control arbiter, tool schemas, targets, registries |
| `Sources/DriverCore/Tools` | The 11 tools |
| `Sources/DriverCore/IPC` | Unix socket server |
| `Sources/MacDriverHost` | Menu-bar app, mirror window, lifecycle |
| `Sources/driverctl` | CLI client |
| `Sources/DriverFixture` | Test fixture app with known controls |
| `clients/python` | Python client |
| `Sources/DriverClient` | Swift client |
| `Tests/E2E` | End-to-end scripts |
