# cua-client

Rust library for embedding ACUA's macOS automation in other programs. It talks
directly to the service over its Unix socket and checks the protocol version.
The service must already be running; the library does not start helper apps
or install anything on the system.

In your program's `Cargo.toml`, use the local path of this folder:

```toml
[dependencies]
cua-client = { path = "/path/to/acua/rust/cua-client" }
```

```rust,no_run
use cua_client::{Action, Client, Result, Target};

fn main() -> Result<()> {
    let mut cua = Client::connect()?;
    let app = "com.apple.TextEdit";
    cua.start_app(app)?;
    let state = cua.appSnapshot(app, true)?;
    println!("{}", state["appSnapshot"]["text"]);

    // Pick the field's current ID from the observation above.
    let field_id = "7";
    cua.perform_action(app, Action::click(Target::element(field_id)))?;
    cua.perform_action(app, Action::type_text("Hello, Rust 🙂"))?;
    cua.stop_app(app)?;
    Ok(())
}
```

## Connecting

`Client::connect_to(path)` connects to a socket you choose. On macOS,
`Client::connect_to_service_bundle("/path/AexComputerUseService.app")` reads the
application group configured in the service's `Info.plist` and resolves its
socket. XML and binary metadata are both accepted, and the app is not launched.

`Client::connect()` resolves the socket in this order:

1. `ACUA_SERVICE_NATIVE_PIPE_PATH`, when set;
2. the service bundle named by `ACUA_SERVICE_NATIVE_BUNDLE_PATH`;
3. the installed service, `computer-use/AexComputerUseService.app` or
   `computer-use/Aex Computer Use.app` inside `AEX_COMPUTER_USE_HOME` (by default
   `~/Library/Application Support/Aex Computer Use`, the folder `make install`
   uses).

Signed packages use the application group of the team that signed them. When
none of the above names an endpoint, `connect()` returns `Error::InvalidInput`.
A bundle with no group, an empty group or an invalid group also returns an
error. Ad-hoc packages disable the group and can use an explicitly configured
socket.

For environment values, `Client::connect()` trims whitespace and newlines from
both ends. `Client::connect_to(path)` uses the path as given. On macOS the
connection also accepts full paths longer than 103 bytes, as long as the final
socket name fits that limit. The library opens the directory on the calling
thread and connects on its own thread, which preserves the program's working
directory and the path bytes. Connection setup stays blocking; the
`ClientOptions` timeout covers the handshake and every RPC call.

`stop_app` ends the automation session; the service decides the app's
lifecycle. Element IDs come from current observations and can change.

## Actions and requests

The nine actions have their own types: click, drag, type text, key/shortcut,
paste, scroll, set value, select text and secondary action. `Point::new`
validates finite coordinates. `MouseButton`, `PasteFormat`, `Direction` and
`Selection` encode the values the service expects. There are also methods for
policies, apps, the frontmost window, staged capture and audio recording.

The WAV returned by `stop_audio_recording` or `stop_audio_recording_typed` is
temporary: the service schedules its deletion 30 seconds after producing the
URL. Read the data or copy the file to keep it. After an automatic stop, collect
the recording within 30 seconds; otherwise the service removes the file and its
ownership data. The delivered file's deadline starts when Stop produces the URL.

If several clients share the recording, wait for every pending Start and Stop
request to finish before starting another one. The service admits these
requests concurrently, so a late earlier response can clear the next
recording's data; the same happens with an earlier start that fails after being
replaced.

For extra buttons, use `MouseButton::Other(5)` or another `u32`.
`Action::Click::click_count` is a `u64` and accepts values up to `i64::MAX`,
like the positive native field. When migrating a `u32` variable, use
`click_count: value.into()`. `Point` coordinates refer to the app's captured
image. `frontmost_window_typed` returns `Option<FrontmostWindow>` with the app's
identifier, its name and the window title when available.

`start_event_stream`, `event_stream_status` and `stop_event_stream` control
event recording. `EventStreamEndReason` keeps the protocol's six end reasons.
The service needs its native storage configured before it can start a
recording; the tests use throwaway directories and windows.

Timeline has typed methods to start, query, pause, resume and stop capture. The
library also reads and edits preferences, updates observation rules and clears
history by period. `TimelineStatus` and `TimelineHistoryInterval` dates are
seconds since 2001-01-01 UTC.

The Calendar calls list calendars and occurrences, read one event, and create,
edit and delete events. Use the IDs returned by the service to read or change
an occurrence. macOS must grant the service full Calendar access. Event dates
are also seconds since 2001-01-01 UTC.

The Messages methods list and search conversations, read messages and images,
and count activity per period. `prepare_messages_send` resolves the recipient
and returns a plan that expires after five minutes. `commit_messages_send`
takes the plan ID, the approved text and the files opened in attachment order.
Use `AsFd::as_fd` to borrow each file. The service accepts up to 64 files per
commit. A commit can consume the plan even when the response says delivery is
uncertain.

Complex responses use `serde_json::Value`; `list_apps` returns `Vec<AppInfo>`.
`AppInfo` offers `is_frontmost()`, `last_used_date()` and `use_count()` when the
service provides those fields. `request::<MyResponse>(name, data)` sends any
other protocol request type, including features the service adds later.

Calls are blocking, serialized through `&mut Client`, with a default timeout of
120 seconds. `ClientOptions` and `RequestOptions` configure timeout and
metadata. In async programs, run the calls on a dedicated thread or on the
runtime's blocking pool. The timeout bounds the whole handshake and each
read/write; the initial connection uses the operating system's `connect`.

`TurnMetadata` converts into a `Value` for `agent_metadata`, keeping the native
keys `session_id`, `turn_id`, `model`, `reasoning_effort`,
`turn_started_at_unix_ms` and `user_input_requested_during_turn`. In recording
responses, numeric dates are seconds since 2001-01-01 UTC; the JSONL files and
on-disk metadata use ISO8601 dates.

## Errors and authorization

`Error::Remote` keeps the native error's code, message and data. Valid service
errors leave the connection usable. Transport errors, expired deadlines and
malformed responses close the client. No action is retried automatically:
after a transport failure it may already have run.

The service keeps its signature checks, app policy and Accessibility/Screen
Recording permissions. For a **local development** service with unsigned Rust
clients, start the service with `ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS=1` and its
own socket. This admits clients of the same user to that service process. The
library does not change this setting, and a signed service may require the
host's signing identity, so an arbitrary Rust client is not guaranteed to
authenticate.

Tests: `cargo test --offline --locked` in this folder. The integration test with
throwaway windows is `node test/rust-client.mjs`, run from the project root.
The client never emulates a feature the service lacks.

### Staged capture

`start_capture_typed` takes `CaptureOptions`, including the permission ID, the
capture protocol version and an optional animation target. Read
`next_capture_update_typed` with the same ID until it reaches `Completed` or
`Failed`. A `PermissionsAbandoned` result ends the attempt before the queue
starts and can report which permissions were granted. Images arrive either as
`screenshot` or as `transition_snapshot_url`. The service returns file URLs for
the client to read.

```rust,no_run
use cua_client::{CaptureOptions, CaptureStartResponse, Client, Result};

fn main() -> Result<()> {
    let mut cua = Client::connect()?;
    let id = "editor-capture-1";
    match cua.start_capture_typed("com.apple.TextEdit", id, &CaptureOptions::default())? {
        CaptureStartResponse::Started { .. } => loop {
            let update = cua.next_capture_update_typed(id)?;
            println!("{update:?}");
            if update.is_terminal() {
                break;
            }
        },
        CaptureStartResponse::PermissionsAbandoned { permission_grant_state, .. } => {
            println!("Granted permissions: {permission_grant_state:?}");
        }
    }
    Ok(())
}
```

### Computer audio

`start_audio_recording_typed` takes `AudioRecordingOptions`. Without an explicit
duration, the service uses 60 seconds. `stop_audio_recording_typed` returns an
`AudioRecording` with the WAV URL, including after an automatic stop. Use the
same session metadata for Start and Stop. When neither request carries session
metadata, the service identifies the owner by the client process.

```rust,no_run
use cua_client::{AudioRecordingOptions, Client, Result};
use std::{thread, time::Duration};

fn main() -> Result<()> {
    let mut cua = Client::connect()?;
    cua.start_audio_recording_typed(AudioRecordingOptions {
        max_duration_milliseconds: Some(5_000),
    })?;
    thread::sleep(Duration::from_secs(1));
    let recording = cua.stop_audio_recording_typed()?;
    println!("{}", recording.url);
    Ok(())
}
```

### State after an action

Use `perform_action_with_app_snapshot` to perform an action and then request
fresh accessibility text and an optional image. These are two standard service
requests. Images use a local file URL and MIME type; files remain available
until the app session is deactivated or stopped. A capture error can follow
successful delivery of the action. The method never retries the action.

### Version 0.2: complete capture responses and generic files

Both `CaptureStartResponse` variants keep the four transition fields and
`permission_grant_state`, all optional, as in the native contract. Present
fields are validated even when they appear on the other variant; invalid data
returns `Error::Json` after consuming the response and leaves the connection
usable. Serialization keeps these fields and omits absent optionals.

Version 0.2 adds fields to both variants. When migrating `match` patterns, use
`..` for fields your program does not use. Explicit constructors must fill the
new optionals with `None` when there is no value. The variant names and
`start_capture_typed` are unchanged.

`request_with_files::<MyResponse>(type, data, options, files)` takes
`&[BorrowedFd]` for any request. The caller keeps ownership of the files; the
receiver gets kernel duplicates that share the read position. On macOS one
transfer carries at most 254 files; other systems can impose a lower limit and
return an I/O error. The service decides which routes consume the attachments.
The call keeps the timeout, metadata, native errors and the rule of never
retrying automatically.

### Version 0.3: actions and observations return different types

`app_snapshot_typed(app, disable_diff)` returns `AppSnapshotResult`, with a
required `appSnapshot` and optional `app_specific_instructions`.
`perform_action_typed(app, action)` returns `ActionResult`, which allows an
optional `appSnapshot` like the native action response.

`perform_action_with_app_snapshot` now returns `AppSnapshotResult`: replace
`result.appSnapshot.unwrap()` with `result.appSnapshot`. App instructions are
kept, including an empty string. Invalid responses produce `Error::Json`
without retrying the action; an invalid acknowledgement prevents the following
read, and a read failure can happen after the action was already sent. The
untyped `appSnapshot` and `perform_action` methods remain available.

### Version 0.3.1: setValue requires text

`Action::set_value(element, text)` builds the action in the native format. Empty
text clears the field; spaces, newlines and Unicode are preserved. The manual
`Action::SetValue { element_id, value }` variant is still available, but
`value` must be a JSON string. The action methods return `Error::InvalidInput`
for booleans, numbers, null, arrays or objects before sending any frame or
consuming a request ID. The connection stays usable. The generic request API
still sends raw JSON explicitly and returns the service's remote errors. No
public type changes.

### Empty acknowledgements and typed core responses

Empty native acknowledgements follow the `ComputerUseIPCEmptyResponse`
contract: any valid JSON result is ignored. Both audio Start methods, Calendar
Delete and `turn_ended` return `Ok(())` for the normal `{}` result. Framing,
malformed JSON and JSON-RPC errors still fail through the shared transport; a
remote error keeps the connection and actions are never retried.

Typed core responses are available through `app_policy_typed`,
`start_app_typed`, `stop_app_typed`, `modify_app_typed`,
`start_event_stream_typed`, `event_stream_status_typed` and
`stop_event_stream_typed`. They keep policy decisions/risk/warnings,
automation-session state, recording paths/dates/end reasons and the signed
duration field. All raw `Value` methods remain available. A typed mismatch
consumes one response and leaves the connection usable; these methods never
retry an action.

```no_run
use cua_client::{AppPolicyDecision, Client};
fn main() -> cua_client::Result<()> {
    let mut client = Client::connect()?;
    let policy = client.app_policy_typed("com.apple.TextEdit")?;
    if policy.decision == AppPolicyDecision::Allowed {
        println!("{}", policy.target.display_name);
    }
    let status = client.event_stream_status_typed()?;
    println!("Recording: {}", status.is_recording);
    Ok(())
}
```

### Native value decoding on macOS

Version 0.4.5 accepts up to 254 borrowed files in a generic request on macOS,
the service's transport limit. The Messages commit limit stays at 64
attachments. Other Unix kernels can reject a transfer earlier; that failure is
returned as an I/O error without retrying the request.

Version 0.4.3 keeps the first occurrence of repeated JSON object keys, including
escaped key spellings and nested objects, as the service's keyed response
decoders do. This applies to response frames and to direct deserialization of
native response models. Every later value is still parsed: malformed JSON
closes the connection, while a valid frame with an invalid typed result permits
the next call. Remote errors require a JSON object. Public field types and
method signatures are unchanged. A caller that has already parsed bytes into
`serde_json::Value` has already chosen its duplicate-key policy; that choice
cannot be undone.

Version 0.4.2 keeps native integral floating spellings and signed limits for
message counts. Image Data validates and canonicalizes Foundation-compatible
Base64 without changing its public String field. On macOS 14.4 and later,
response URL fields follow Foundation encoding and validation rules, including
optional Calendar and capture-transition URLs. The status menu uses the exact
bundleURL wire key. Other Unix targets keep string decoding for URLs; URL
decoding is validated on macOS only. These conversions keep public field types
and method signatures.
