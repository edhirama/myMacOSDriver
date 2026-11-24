# MacDriver calling contract

Scripts call tools with one entry point, `driver.call(request)`, and get a JSON response back.

| Client | Usage |
|---|---|
| Python | `from driver import driver; driver.call({"name": "computer_apps", "arguments": {}})` (`clients/python/driver.py`) |
| Swift | `import DriverClient; try Driver().call(["name": "computer_apps", "arguments": [:]])` (`Sources/DriverClient`) |
| CLI | `build/driverctl call computer_apps '{}'` or `build/driverctl call '{"name": ..., "arguments": {...}}'` |
| Anything else | Write one JSON object per line to the Unix socket and read one JSON line back |

**Socket:** `~/Library/Application Support/MacDriver/driver.sock`. Override it with `MACDRIVER_SOCKET`. The socket file has mode 0600, so only the current user can connect.

## Request

```json
{ "id": "optional-idempotency-key", "name": "computer_click",
  "arguments": { "in": "shot:ab12cd.3", "x": 300, "y": 200 },
  "timeout_ms": 15000 }
```

| Field | Meaning |
|---|---|
| `name` | One of the 11 tool names. |
| `arguments` | The tool's parameters. Unknown keys are rejected, never ignored. Every tool also accepts `computer`. |
| `id` | Idempotency key, at most 200 characters. The Python and Swift clients and the CLI generate one when you omit it. A raw request without one gets a server-generated `auto-<uuid>` id, echoed in the response, but that gives no retry protection, because a client that lost the reply never learned it. **Re-sending the same id never repeats side effects** (see [Retries](#retries-and-idempotency)). |
| `timeout_ms` | Deadline for the whole call, including time spent paused while the user has control. Each tool has a default (15–60 s). |

Control messages on the same socket:

- `{"op":"cancel","id":"<id>"}` stops a running call at its next safe point.
- `{"op":"status"}` returns the host state: display, control owner, targets, permissions, arrangement check, in-flight calls and held inputs. It also has `capabilities` (which of the private macOS features this system provides, and what is lost without each; `stage_manager_off` is false while Stage Manager is on, when windows cannot be minimized) and `interrupted_requests` (requests a previous host process left unfinished).
- `{"op":"tools"}` lists the 11 tools. Each entry has `name`, `description`, `mutating`, `default_timeout_ms` and `input_schema`, a JSON Schema of the arguments generated from the same declarations the host validates against. `driverctl tools` and `Driver().tools()` call it.

## Response

```json
{ "id": "…", "name": "computer_type", "ok": true,
  "result":   { … tool specific … },
  "dispatch": "dispatched",
  "effect":   { "confirmed": true, "evidence": ["ax_value_changed", "text_present_in_value"] },
  "warnings": [],
  "replayed": false,
  "duration_ms": 412 }
```

A call that was paused by a takeover also has `"paused_ms"`, the part of `duration_ms` spent waiting for Give Back.

```json
{ "paused_ms": 5310 }
```

On failure, `ok` is `false` and `error` is present: `{ "code": "...", "message": "...", "details": {...} }`.

### Dispatch and effect

`dispatch` says whether input reached the application:

| `dispatch` | Meaning |
|---|---|
| `none` | No input or accessibility action was performed. This covers observation tools and anything rejected during validation. |
| `dispatched` | All input for the call was delivered. |
| `partial` | Some input was delivered before the call stopped (cancel, timeout, or a takeover it could not resume from). `warnings` says how much, for example "Typed 12 of 40 characters". |
| `unknown` | The host stopped while the call was running, so how much was delivered is not known. Only returned with `unknown_outcome`. |

`effect` says what the driver observed afterwards:

- `confirmed: true` means at least one independent signal shows the app reacted.
- `confirmed: false` with `dispatch: dispatched` means the input was sent, but no change could be observed. For example, scrolling at the end of a list produces no change.

Evidence values:

| Evidence | What was observed |
|---|---|
| `ax_notification` | The app itself announced a change while the action ran. The specific announcements are listed next to it: `ax_value_changed`, `ax_selection_changed`, `window_frame_changed`, `window_created`, `sheet_created`, `window_minimized`, `window_restored`, `menu_opened`, `title_changed`. |
| `element_destroyed`, `window_focus_changed` | Also announced by the app, but not proof of an effect on their own. |
| `screen_changed` | The display's fingerprint differs before and after. |
| `resumed_after_takeover` | The call was paused by a takeover and continued after Give Back. |
| `focus_changed` | The app's focused element changed. |
| `ax_value_changed` | The focused element's value changed. |
| `text_present_in_value` | The typed text is present in the element's value. |
| `ax_action_accepted` | The app accepted an accessibility action such as `AXPress`. |
| `window_frame_changed` | The window frame changed. |
| `state_read_back`, `frame_read_back` | The requested state or frame was read back from the app. |
| `new_windows` | The app created new windows. |
| `window_placed_on_target` | A window was moved onto the target display. |
| `window_gone` | The window no longer exists. |
| `prompt_shown` | A save prompt or dialog appeared. |
| `scroll_position_changed` | The AX scroll position changed. |
| `window_made_key` | The window was made key inside its app (input preparation, not an effect). |

### Error codes

| Code | When |
|---|---|
| `invalid_request` | Malformed JSON or envelope. |
| `unknown_tool` | `name` is not one of the 11 tools. |
| `invalid_argument` | Missing or wrong-typed argument, an unknown argument, or a forbidden combination. |
| `unknown_target` / `target_unavailable` | Bad `computer` value, or the virtual monitor is not running. |
| `unknown_app` / `unknown_window` / `window_not_on_target` | The id doesn't resolve, or it's on a different target. |
| `unknown_screenshot` / `stale_screenshot` | The screenshot id isn't known, or its window was resized or the display changed. |
| `stale_ref` | The element from a snapshot no longer exists or moved to another window. |
| `out_of_bounds` | The coordinates are outside the image or display, or nothing is at the point. |
| `no_input_target` | `type` or `key` was called without a valid preceding click on that target, or focus moved to another window. |
| `user_has_control` | The user still had control when the call's timeout expired, or took control in the middle of a held gesture such as a drag (`details.resumable: false`). |
| `target_changed` | A call paused by a takeover found its target changed when control came back: the window closed, or the caret or keyboard focus moved. It did not continue. |
| `unknown_outcome` | The host stopped while this request was running. It was not run again; observe the state and continue under a new id. |
| `cancelled` / `timeout` | The call was stopped by `cancel`, by a disconnect that no retry followed within 2 s, or by its deadline. |
| `id_conflict` | The same `id` was reused for a different request. |
| `accessibility_unavailable` | The AX tree can't be read. `details.fallback` is `computer_screenshot`. |
| `permission_missing` | Accessibility or Screen Recording isn't granted. |
| `unsupported` | The operation can't be done safely on this target (for example system UI, or an app without a New Window command). |
| `action_failed` | The app refused an action, or the point is covered by another app's window. |

## Targets and coordinates

- **`computer`:** omit it (or pass `"virtual"`) for the virtual monitor. Physical displays must be named explicitly as `"display:<id>"`. `computer_apps.display` and `status.targets` list the ids. Calls never switch targets on their own.
- **Coordinates:** all coordinates are in the target display's points, with the origin at the top-left, `x` increasing to the right and `y` increasing downward. `frame` is `{x, y, width, height}` in the same space.
- **Screenshot positions (`in` + `x` + `y`):** these are pixel coordinates inside that screenshot. The screen point is `origin + (x, y) / scale`, using the `origin` and `scale` returned by `computer_screenshot`. Screenshots default to `scale: 1`, so image pixels equal display points. Window screenshots re-map to the window's current position if it moved. They are rejected if the window was resized or closed.
- **Refs:** `ref` values come from `computer_snapshot`. They are re-validated on every use: the element must still exist, still be in the same window, and still be on the target.
- **No mixing:** passing both position forms is `invalid_argument`.

## Tools

All tools accept `computer`. Optional parameters are marked `?`.

| Tool | Arguments | Result |
|---|---|---|
| `computer_apps` | — | `apps[]`: `{app, name, bundle_id, pid, windows[]: {window, title, frame, state, main, focused_in_app, z_order}}`, plus `display`. |
| `computer_open` | `app?`, `path?`, `intent?` | `{app, launched, windows[]: {window, title, frame, status: created\|reused, placement}}`. `placement` is one of `moved_to_target`, `already_on_target`, `on_other_display_not_moved` or `move_failed`. |
| `computer_screenshot` | `window?`, plus extensions `format?` (png\|jpeg), `resolution?` (points\|pixels), `return?` (base64\|path) | `{screenshot, width, height, scale, origin, mime_type, image_base64 \| path}` |
| `computer_snapshot` | `window?`, plus extensions `scope?` (all\|visible), `detail?` (full\|compact), `query?` | `{window, app, title, selected_by, node_count, ref_count, truncated, tree}`, or `matches[]` and `match_count` in place of `tree` when `query` is given. Each tree node has `role`, `subrole`, `name`, `value`, `states[]`, `frame`, `actions[]`, `ref` and `children[]`. Values longer than 500 characters are cut, with the full length in `value_length`. |
| `computer_click` | `in`+`x`+`y` \| `ref`, `button?`, `count?` (1–3), `keys?` | `{window, point, method: ax_press\|ax_text_selection\|ax_press_at_point\|events, focused_element, selection?}`. On editable text, a click places the caret, `count` 2 or 3 selects a word or line, and `selection` holds the resulting character range. |
| `computer_drag` | `in`, `path` (≥2 points), `button?`, `keys?` | `{window, method, title_bar, window_frame}` |
| `computer_scroll` | position, `direction`, `amount`, `keys?` | `{window, point, direction, ticks, method: events\|events+ax_scrollbar, position}`. `position` is the AX scroll position, 0–1. |
| `computer_type` | `text` | `{window, characters, element}` |
| `computer_key` | `key`, `repeat?` | `{window, key, repeat, focused_element}` |
| `computer_window` | `window`, `state?`, `frame?` | `{window, state, frame}`: the state and frame read back from the app. |
| `computer_close` | `window` | `{closed, status: closed\|prompt_pending\|still_open, prompt?: {window, text[], buttons[]: {ref, name}}}` |

**Snapshots of large windows.** A web page can have thousands of elements, and a snapshot stops at 1,500 (`truncated: true`, with a warning). Three optional arguments narrow it:

- `scope: "visible"` leaves out everything scrolled out of the window.
- `detail: "compact"` leaves out groups that have no name, value or action; what they contain moves up a level.
- `query: "text"` returns a flat `matches[]` list of the elements whose name, value, placeholder, identifier or role contains the text (case-insensitive, at most 200), each with its `ref`.

On one shop's home page the full snapshot was cut off at 1,500 elements (347 KB); with `scope: visible` and `detail: compact` it was complete at 306 elements (77 KB).

**Web pages.** Chromium-based apps (Chrome, Edge, Electron apps) expose their page content to accessibility only on request. The first `computer_snapshot` of such an app makes the request and waits up to 2 s for the page tree; `computer_screenshot` never does. Inside a web page every click is delivered as real pointer events (a move, then press and release) even when a `ref` is given, because pages and their bot checks only see input that runs their own handlers.

`keys` holds modifiers held during the action. It's an array or a `+`-joined string of `shift`, `ctrl`, `alt` (Option) and `super` (Command).

`key` accepts:

- names such as `Return`, `Tab`, `Escape`, `Backspace`, `Delete`, `ForwardDelete`, `ArrowLeft/Right/Up/Down`, `Home`, `End`, `PageUp`, `PageDown` and `F1`–`F15`;
- single characters;
- combinations such as `super+a` or `ctrl+shift+Tab`.

## Retries and idempotency

| Situation | What the host does |
|---|---|
| The same `id` is still running | The second request attaches to the running call. Nothing runs twice. |
| The same `id` already finished | The host returns the stored response with `replayed: true`. |
| A failure with `dispatch: none` (validation error, `user_has_control` before acting, timeout before acting) | Not stored. Retrying with the same id runs it again, which is safe because nothing happened. |
| The same `id` with different arguments | `id_conflict`. |
| A client disconnects | Its in-flight calls keep running for 2 s. A client that reconnects and re-sends the same id within that time attaches to the call and gets its real result. If no connection is waiting on the call after 2 s, it is cancelled; a later re-send gets the stored, possibly `partial`, result. |
| The host restarted after the `id` finished | Same as above: the stored response, `replayed: true`. Calls that can have side effects are journaled to `requests.journal` next to the socket. |
| The host stopped while the `id` was running | `unknown_outcome` with `dispatch: unknown`. The request is never run a second time, because part of its input may already have been sent. |

Observation tools are not journaled. After a restart they simply run again, which is harmless.

## Take Control and pausing

When the user presses **Take Control** in the mirror window or the menu-bar menu, nothing is cancelled. Script calls pause, and continue after **Give Back**:

1. A running mutating call stops before its next input event and waits. Any pressed keys or buttons are released.
2. New mutating calls wait before starting.
3. On Give Back, each paused call checks that its target is unchanged, then continues where it stopped. A 500-character `computer_type` paused at character 213 types the remaining 287.
4. Calls resume in the order they were queued, one at a time per target.

A paused call ends in an error instead of continuing in three cases:

| Case | Error | `dispatch` |
|---|---|---|
| The call's `timeout_ms` expires while it is paused | `user_has_control` | `partial`, or `none` if it had not started |
| The takeover happened in the middle of a held gesture (a drag with the button down). The button was released, so the gesture cannot be continued. | `user_has_control`, `details.resumable: false` | `partial` |
| The target changed while the user had control: the window was closed or moved off the target, another window covers the point, or (for `type` and `key`) keyboard focus or the caret moved | `target_changed` | `partial` or `none` |

A resumed call reports `paused_ms`, a warning with the same figure, and the evidence `resumed_after_takeover`.

Observation tools (`apps`, `screenshot`, `snapshot`) keep working during a takeover, so a script can watch. Closing the mirror window does not give control back.

The input location set by earlier clicks is discarded on takeover. A paused `type` or `key` call keeps its own location (and checks it on resume), but a later call must click again before typing.
