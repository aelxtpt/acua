# GPUI apps: empty accessibility tree and actions that seem to be ignored

Status: posted on 2026-11-27 as issue 1 of this project.

## Summary

Against a GPUI app (GPUI fork `zeronsh/zui` at `361ff20`), ACUA 0.5.0 returned
success for clicks, drags and key presses while the tree and the screenshot it sent back did not change. Twice in
one session an agent concluded that ACUA's input never reached the app.

The input did reach the app. What stopped was what ACUA reads back: a GPUI window that is not drawing frames
publishes no new accessibility tree and no new picture. ACUA's part of the fault is that it reported this as a plain
success, and that a window it could not match for a moment failed the call instead of being read again.

## What happened

Symptom A, about 22 s after the app was reopened by its install script:

- `get_app_state` returned the window, its three standard buttons and the menu bar. No content elements.
- Four `click` calls at `x`/`y` on a sidebar button, one of them after `perform_secondary_action` "Raise", returned
  the same six-line tree and the same picture. No error.
- Six and a half minutes later `get_app_state` returned the full tree, and the app was already on the page those
  clicks aimed at.

Symptom B, same process, a few calls later:

- `click` by `element_index`, `type_text` and one `drag` worked. The drag moved a card between two columns, and the
  app saved the move.
- Every call in the next 3 min 44 s returned the tree and picture from just after the drop: `click` by index and
  by `x`/`y`, `press_key` Escape, two more `drag` calls. No error.
- The app was idle in its event loop at 0% CPU.
- After quit and reopen the same sequence worked.

## Steps to reproduce

What reproduces on demand, with any GPUI app that uses AccessKit:

1. Open the app and call `get_app_state`. The tree is complete.
2. Cover the app's window completely with an opaque window of another app.
3. `click` a button by `element_index`.
4. The returned tree shows the click's effect. The screenshot does not, in this call or in later `get_app_state`
   calls, until the window is uncovered.

What reproduced on a first contact with a new process (3 of 3 tries with these steps):

1. Open the app, then activate another app.
2. Leave it alone for about 30 s.
3. Call `get_app_state`: `Computer Use server error -10005: windowUnavailable`.

In the one try that was carried on, the next calls gave:

4. `get_app_state`: the six-line tree of symptom A.
5. `click` at `x`/`y`: `Computer Use server error -10005: noWindowsAvailable`.
6. `get_app_state`: the full tree.

A process opened in the background, or one that stayed frontmost, gave the full tree on the first call.

The minutes-long freeze after a drag (symptom B) did not reproduce.

## Expected

- A call whose result cannot show what the action did says so.
- A window that cannot be matched for a fraction of a second does not fail the call.

## Cause

In GPUI, not in ACUA:

- GPUI sends its AccessKit tree only when it draws a frame (`Window::draw`, `crates/gpui/src/window.rs`). The first
  accessibility query is answered with a placeholder that holds only the root window, and GPUI asks for a frame.
- On macOS that fork draws on demand from a display link that is not started while the window is not visible to the
  WindowServer and is paused while the window is idle (`start_display_link` and `pause_frame_requests` in
  `crates/gpui_macos/src/window.rs`).
- With no frame, the tree stays at the placeholder or at its last state, and the window's picture stays old. Mouse
  events and accessibility actions are still handled. GPUI turns an accessibility Click into a mouse down and up at
  the centre of the node (`handle_a11y_action`).

In ACUA:

- `get_app_state` and every action returned such a snapshot as a normal success. Nothing told the agent that the tree
  had no content or that the picture could be old.
- A capture fails with `windowUnavailable` when the accessibility window cannot be matched to a WindowServer window
  at that instant, although the next read finds it.

Not found:

- Why the app stopped drawing for 3 min 44 s in symptom B and for at least 34 s in symptom A. What covered the
  window at those moments is not recorded.
- Why, in two of the first-contact tries, the test app's window was at 90% of its size just before ACUA's first call
  and animated back as the call arrived. Nothing in ACUA scales windows, and no window manager was running.

Ruled out:

- A mouse button left down by `drag`: the app received the mouse up, since the drop was saved, and drag followed by
  clicks works when the app is drawing.
- A stale event target after `drag`: clicks by index go through the accessibility action, not through posted events,
  and froze in the same way.
- A coordinate click with nothing to press: coordinate clicks post real mouse events to the app's process whatever
  the tree holds.
- The app hanging: its main thread was idle.

## Fix

In this repository:

- `service/ClientMCPAutomationFormatting.swift`: when a window in the returned tree holds nothing but its standard
  buttons, the MCP result carries a warning. For `get_app_state` it says the app has not published its UI tree and
  the screenshot can be out of date. For an action it says the action was sent, its effect cannot be confirmed, and
  it should not be repeated before the tree is back.
- `service/Native/controller-native-operations/ControllerAppSnapshotOperation.swift` and
  `service/Native/native-screenshot-capture-pipeline/ControllerNativeAppSnapshot.swift`: a capture that fails with
  `windowUnavailable` is retried up to four more times, 200 ms apart, before the error is returned.
- Tests: `test/acua-mcp-output.swift` (12 new checks) and `test/acua-app-snapshot-retry.swift` (5 checks, target
  `acua-app-snapshot-retry-test`).

The action results are warnings, not errors, on purpose. In every observed case the action had been delivered, and
an error would invite the agent to repeat a click that already took effect.

State on 2026-11-27: the fix is in the working tree, not committed. A build with it is installed on the Mac where
the failures were seen.

Checked with that build:

- First contact with the test app after about 34 s in the background returned the full tree in 2 of 2 tries. It was
  `windowUnavailable` in 3 of 3 before. Whether the retry ran in those tries is not known.
- The GPUI app where the failures were seen: a drag, a click by `element_index`, a click by `x`/`y` and a second drag all showed
  their effect in the tree and in the picture.
- The warning was not seen live. No empty tree came back after the install.

Not fixed here:

- The screenshot of a covered GPUI window still shows the old picture with no warning, because the tree is complete
  in that case. Detecting it needs a comparison of the picture before and after the action.
- GPUI not drawing. That belongs in the GPUI fork or in the app: publish the AccessKit tree without waiting
  for a frame, or draw one frame when accessibility is activated or an accessibility action is handled, even while
  the display link is stopped.
