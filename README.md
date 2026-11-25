# ACUA - Computer Usage

ACUA lets an AI agent use the apps on your Mac. It reads an app's window
through the accessibility tree and a screenshot, then clicks, types, scrolls
and drags inside it. An on-screen "Agent" cursor shows where each pointer
action lands. You keep using the Mac while it works.

It is agent-neutral. Any agent can use it through:

- **an MCP server** (stdio or local HTTP), for Claude Code, Cursor, Codex and
  other MCP hosts;
- **a Rust library** ([`rust/cua-client`](rust/cua-client/README.md)), for
  programs that want to talk to the service directly;
- **a CLI**, which sets up hosts and ends agent turns.

Before the agent touches an app for the first time, you approve it, or you
list it in `~/.acua/config.toml`.

## MCP tools

The default server, `acua`, gives an agent these tools:

| Tool | What it does |
|---|---|
| `list_apps` | Lists the apps the agent can use |
| `get_app_state` | Returns an app's accessibility tree, with element indexes, and a screenshot |
| `click` | Clicks an element (by `element_index`) or a point in the screenshot |
| `perform_secondary_action` | Runs an element's other accessibility actions, such as expand or show menu |
| `set_value` | Sets the value of a text field, slider or similar element |
| `select_text` | Selects text inside an element |
| `scroll` | Scrolls an element or a point |
| `drag` | Drags from one point to another |
| `press_key` | Presses a key or a shortcut, in xdotool syntax, such as `Return` or `super+t` (⌘T) |
| `type_text` | Types text into the focused element |
| `end_turn` | Tells ACUA the agent's turn is over (see [Turns](#turns)) |

The usual loop: `get_app_state`, pick an element from the tree, act on it,
then `get_app_state` again to see the result.

Four optional servers come in the same helper. Each needs its own macOS
permission:

| Server | Tools |
|---|---|
| `acua-calendar` | `list_calendars`, `list_events`, `get_event`, `create_event`, `update_event`, `delete_event` |
| `acua-messages` | `find_chats`, `read_messages`, `search_messages`, `send_message`, `count_message_activity`, `read_image` |
| `acua-computer-history` | pause, resume and configure the local activity history |
| `acua-event-stream` | `event_stream_start`, `event_stream_status`, `event_stream_stop` (screen and accessibility recording) |

Reading or sending messages and starting a recording also ask for your
approval.

## Requirements

- macOS 14.4 or later. The build targets the Mac's own architecture.
- Xcode or the Command Line Tools, with Swift 6, and Python 3.
- A code-signing identity that belongs to an Apple developer team, such as
  an Apple Development certificate. The service only accepts clients signed
  by the same team, so an ad-hoc signature (`-`) builds but cannot be used.

To find your identity:

```bash
security find-identity -v -p codesigning
```

Use the 40-character hash on an "Apple Development" or "Developer ID
Application" line. If you have none, open Xcode, go to Settings → Accounts,
add your Apple ID and create an Apple Development certificate.

## Build and install

```bash
git clone <this repository> acua
```

```bash
cd acua/service
```

```bash
make bundle CODESIGN_IDENTITY=<your identity hash>
```

The signed app is now at `service/.build/current/dist/AexComputerUseService.app`.
Copy it to your Applications folder:

```bash
ditto .build/current/dist/AexComputerUseService.app ~/Applications/AexComputerUseService.app
```

The MCP helper lives inside the app. The commands below use it often, so keep
its path in a variable:

```bash
ACUA=~/Applications/AexComputerUseService.app/Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient
```

You don't need to start anything yourself. The helper launches the service
the first time an agent calls a tool.

### macOS permissions

The service needs two permissions, both granted to **Aex Computer Use** in
System Settings → Privacy & Security:

- **Accessibility**, to read windows and send input;
- **Screen & System Audio Recording**, for screenshots.

macOS asks the first time they're needed. If you missed the prompt, turn them
on in System Settings and run the tool call again.

## Add ACUA to your agent

`mcp install` prints the configuration for a host, using the helper's real
path. It writes nothing unless you add `--write`.

### Claude Code

```bash
"$ACUA" mcp install --client claude-code --approval-prompt service
```

It prints a `claude mcp add` command. Run it to add ACUA for every project:

```bash
claude mcp add --scope user acua -- "$ACUA" mcp --approval-prompt service
```

To add it to one project only, run `mcp install` with `--write` inside that
project. That writes `./.mcp.json`.

Restart Claude Code, then check with `claude mcp list`. This works in the
terminal and in the Claude desktop app's Code tab.

Why `--approval-prompt service`: Claude Code declares MCP elicitation but
doesn't always show the form. The desktop app declines it silently and
`claude -p` cancels it, so the approval would fail without a prompt. With this
option ACUA always shows its own dialog. See [Approvals](#approvals).

### Claude desktop app (chat)

The chat side of the Claude desktop app reads
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```bash
"$ACUA" mcp install --client generic --approval-prompt service --write --config ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

This keeps the servers already in the file. Quit and reopen the Claude app to
load it. The Code tab uses Claude Code's own configuration, shown above.

### Cursor

```bash
"$ACUA" mcp install --client cursor --write
```

This edits `~/.cursor/mcp.json` and keeps the servers already in it. Without
`--write`, it prints the JSON to paste yourself.

### Codex

Codex reads TOML, so add the server by hand to `~/.codex/config.toml`:

```toml
[mcp_servers.acua]
command = "/Users/<you>/Applications/AexComputerUseService.app/Contents/SharedSupport/AexComputerUseClient.app/Contents/MacOS/AexComputerUseClient"
args = ["mcp"]
```

Each optional server is another entry with the same `command`. Its `args`
start with the server's name, for example `args = ["calendar", "mcp"]` under
`[mcp_servers.acua-calendar]`. `"$ACUA" mcp install --client generic --server <name>`
prints the exact `args` for any server.

### Any other MCP host

For a host that reads the common `{"mcpServers": {...}}` JSON:

```bash
"$ACUA" mcp install --client generic --write --config <path to the host's JSON file>
```

Without `--write` and `--config`, it prints the entry. Add
`--approval-prompt service` if the host never shows elicitation forms. For
example, Windsurf reads `~/.codeium/windsurf/mcp_config.json`.

### More than one server

`--server` picks the servers and can be repeated. The default is
`computer-use`:

```bash
"$ACUA" mcp install --client claude-code --server computer-use --server calendar --server messages
```

The values are `computer-use`, `calendar`, `computer-history`, `event-stream`
and `messages`.

### HTTP instead of stdio

For an agent that can't start a local process:

```bash
"$ACUA" mcp --http 8765
```

It listens only on `127.0.0.1` (`0` picks a free port). On every start it
prints the URL (`http://127.0.0.1:<port>/mcp`) and a new token to standard
error. Send the token as `Authorization: Bearer <token>`. The token is never
written to disk. To reach it from another machine, use your own tunnel, such
as SSH.

### Try it

Ask your agent something like:

> Use acua to open a new tab in Google Chrome and search for "hacker news".

The first call to a new app opens the approval dialog. Choose **Allow** or
**Always Allow**, and the agent goes on.

## Approvals

The agent can use an app only after you approve it. The approval is asked in
one of two places:

- **The host's own form**, when the host supports MCP elicitation. This is the
  default, `--approval-prompt client`.
- **ACUA's dialog**, when the host doesn't support elicitation, or always with
  `--approval-prompt service`.

The dialog has three buttons:

- **Deny**, the default button;
- **Allow**, while the agent stays connected;
- **Always Allow**, saved for later sessions. It appears only when
  `allow_persistent_approval = true`, the default.

If nobody answers within 110 seconds, or the agent disconnects, the dialog
closes and the call fails.

Apps listed in `[apps].allow` never ask. Apps in `[apps].deny` are refused
before any dialog. Use `allow` for agents that run without a screen, such as
`claude -p`.

## Turns

When you take over an app while the agent is using it, for example by
clicking or typing in it yourself, ACUA pauses the agent's access to that app
until the agent's turn ends. The next turn can use it again.

An agent ends its turn in one of three ways:

- calling the MCP tool `end_turn`;
- a stop hook that runs `turn-ended`, which you can install with
  `hooks install`;
- `client.turn_ended(...)` in the Rust library.

To install the hook:

```bash
"$ACUA" hooks install --client claude-code --write
```

| Agent | File it edits | Hook |
|---|---|---|
| `claude-code` | `~/.claude/settings.json` | `Stop` runs `AexComputerUseClient turn-ended --agent-process` |
| `cursor` | `~/.cursor/hooks.json` | `stop` runs the same command |
| `codex` | `$CODEX_HOME/config.toml` | `notify = ["…/AexComputerUseClient", "turn-ended"]`, keeping an existing `notify` |

`--config` picks another file, such as a project's `.claude/settings.json`.
`hooks uninstall` removes only ACUA's hook.

An agent can also name its session and turn in each call's `_meta`:

```json
{"x-acua-turn": {"session_id": "…", "turn_id": "…"}}
```

Without it, every call from the same agent process shares one session.

## Configuration: `~/.acua/config.toml`

Every key is optional, and a missing file uses the defaults. A misspelled
table or key is an error, never ignored, so a typo in `deny` can't silently
allow an app. Set `ACUA_HOME` to use another folder. Changes apply on the
next call, without restarting anything.

```toml
[apps]
enabled = true                  # false turns every computer-use call off
default_access = "allow"        # "allow" or "deny" for apps in neither list
allow = ["com.apple.TextEdit"]  # never ask for these
deny = ["com.apple.Terminal"]   # always refuse these
allow_persistent_approval = true

[screenshots]
resolution = "fit"        # "fit": one pixel per point, within 2048×768; "native": every pixel
max_image_bytes = 750000  # per image, before base64; 0 means no limit
format = "jpeg"           # "jpeg" or "png"
jpeg_quality = 0.8

[privacy]
blocked_domains = ["bank.example"]  # never captured, subdomains included
```

`allow` and `deny` take bundle identifiers and compare them without case. To
find an app's identifier:

```bash
osascript -e 'id of app "TextEdit"'
```

If a screenshot goes over `max_image_bytes`, ACUA lowers the JPEG quality
but never changes the image size, so click coordinates stay valid. The
default keeps each image result under about 1 MB.

## Rust library

[`rust/cua-client`](rust/cua-client/README.md) talks to the running service
over its socket. Add it as a path dependency:

```toml
[dependencies]
cua-client = { path = "path/to/acua/rust/cua-client" }
```

The program must be signed by the same team as the service.

## Remove ACUA

```bash
claude mcp remove --scope user acua
```

```bash
"$ACUA" hooks uninstall --client claude-code --write
```

```bash
rm -rf ~/Applications/AexComputerUseService.app
```

For Cursor or a generic host, `mcp uninstall` takes the same `--client`,
`--server`, `--write` and `--config` options as `mcp install`. Then remove
**Aex Computer Use** from Accessibility and Screen Recording in System
Settings.

## Tests

Unit tests need no service and no permissions:

```bash
make -C service acua-mcp-install-test acua-mcp-approval-test acua-configuration-test
```

The full suite drives real apps and needs the permissions above:

```bash
bash test/all.sh --list
```

```bash
bash test/all.sh --group 1
```
