//! Blocking, embeddable client for the macOS Computer Use service.
//!
//! One client serializes its requests through `&mut self`. Use a dedicated
//! thread (or your async runtime's blocking pool) for calls from async code.
//! The service must already be running. Transport failures close this client;
//! actions are never retried automatically because they may have taken effect.
#![doc = include_str!("../README.md")]
#![cfg(unix)]

// Swift keyed Codable responses require an object, even when an array has the
// same number and order of values. Preserve all public fields and existing traits.
macro_rules! native_response_object {
    (#[derive($($traits:path),* $(,)?)] $(#[$meta:meta])* pub struct $name:ident {
        $($(#[$attr:meta])* pub $field:ident: $ty:ty),* $(,)?
    }) => {
        #[derive($($traits),*)]
        #[serde(try_from = "crate::native_json::NativeValue")]
        $(#[$meta])*
        pub struct $name { $($(#[$attr])* pub $field: $ty),* }
        impl TryFrom<crate::native_json::NativeValue> for $name {
            type Error = serde_json::Error;
            fn try_from(value: crate::native_json::NativeValue) -> std::result::Result<Self, Self::Error> {
                Self::try_from(value.0)
            }
        }
        #[doc(hidden)]
        impl TryFrom<serde_json::Value> for $name {
            type Error = serde_json::Error;
            fn try_from(value: serde_json::Value) -> std::result::Result<Self, Self::Error> {
                #[derive(serde::Deserialize)]
                $(#[$meta])*
                struct Fields { $($(#[$attr])* $field: $ty),* }
                let fields: Fields = crate::core::object_fields(value)?;
                Ok(Self { $($field: fields.$field),* })
            }
        }
    }
}

// A remote derive reuses one enum declaration for native parsing and public
// serialization, keeping variant names and field mappings together.
macro_rules! native_tagged_response {
    ($remote:literal; $(#[$meta:meta])* pub enum $name:ident { $($variants:tt)* }) => {
        #[derive(Debug, Clone, PartialEq, serde::Serialize)]
        $(#[$meta])*
        pub enum $name { $($variants)* }
        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
                #[derive(serde::Deserialize)]
                #[serde(remote = $remote)]
                $(#[$meta])*
                enum Fields { $($variants)* }
                let crate::native_json::NativeValue(value) =
                    <crate::native_json::NativeValue as serde::Deserialize>::deserialize(deserializer)?;
                if !value.is_object() {
                    return Err(serde::de::Error::custom("native response requires a JSON object"));
                }
                Fields::deserialize(value).map_err(serde::de::Error::custom)
            }
        }
    }
}

mod actions;
mod audio;
mod calendar;
mod capture;
mod core;
mod foundation;
mod messages;
mod native_json;
mod timeline;
mod unix_socket;
mod service_endpoint;
pub use service_endpoint::service_bundle_socket_path;
pub use actions::*;
pub use audio::*;
pub use calendar::*;
pub use capture::*;
pub use core::*;
pub use messages::*;
pub use serde_json::Value;
pub use timeline::*;

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::json;
use std::{
    env,
    ffi::OsStr,
    fmt,
    io::{self, Read, Write},
    net::Shutdown,
    os::{
        fd::{AsRawFd, BorrowedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const API_VERSION: &str = "AcuaComputerUseIPC-5";
pub const MAX_FRAME_BYTES: usize = 8_388_608;
const MAX_FRAME_FILES: usize = 254;

#[derive(Debug, Clone)]
pub struct ClientOptions {
    pub api_version: String,
    /// Whole RPC deadline, including writing and reading all frame fragments.
    pub timeout: Duration,
    pub agent_metadata: Option<Value>,
}
impl Default for ClientOptions {
    fn default() -> Self {
        Self {
            api_version: API_VERSION.into(),
            timeout: Duration::from_secs(120),
            agent_metadata: None,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct RequestOptions {
    pub timeout: Option<Duration>,
    /// Overrides the client's metadata. `Some(Value::Null)` sends JSON null.
    pub agent_metadata: Option<Value>,
}

native_response_object! {
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FrontmostWindow {
    pub bundle_identifier: String,
    pub name: String,
    pub window_title: Option<String>,
}
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct RemoteError {
    pub code: i64,
    pub message: String,
    #[serde(default)]
    pub data: Option<Value>,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidInput(String),
    Protocol(String),
    Remote(RemoteError),
    VersionMismatch { client: String, server: String },
    Closed,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "CUA transport: {e}"),
            Self::Json(e) => write!(f, "CUA JSON: {e}"),
            Self::InvalidInput(e) => write!(f, "Invalid CUA input: {e}"),
            Self::Protocol(e) => write!(f, "Invalid CUA response: {e}"),
            Self::Remote(e) => write!(f, "CUA error {}: {}", e.code, e.message),
            Self::VersionMismatch { client, server } => {
                write!(f, "CUA version mismatch: client={client}, server={server}")
            }
            Self::Closed => f.write_str("CUA connection is closed"),
        }
    }
}
impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            Self::Json(e) => Some(e),
            _ => None,
        }
    }
}
impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e)
    }
}
pub type Result<T> = std::result::Result<T, Error>;

/// Resolves the macOS service socket from the environment or the installed
/// ACUA service bundle. Fails when neither names an endpoint.
pub fn default_socket_path() -> Result<PathBuf> {
    let override_path = env::var_os("ACUA_SERVICE_NATIVE_PIPE_PATH");
    if let Some(path) = override_path.as_deref().and_then(socket_override) {
        return Ok(path.into());
    }
    if let Some(bundle) = env::var_os("ACUA_SERVICE_NATIVE_BUNDLE_PATH")
        .as_deref().and_then(socket_override) {
        return service_bundle_socket_path(bundle);
    }
    let home = env::var_os("HOME")
        .filter(|p| !p.is_empty())
        .ok_or_else(|| Error::InvalidInput("HOME is missing; use Client::connect_to".into()))?;
    let home = PathBuf::from(home);
    #[cfg(target_os = "macos")]
    if let Some(path) = service_endpoint::installed_service_socket_path(&home)? {
        return Ok(path);
    }
    Err(Error::InvalidInput(
        "no installed ACUA service found; set ACUA_SERVICE_NATIVE_PIPE_PATH or use Client::connect_to".into(),
    ))
}

fn socket_override(path: &OsStr) -> Option<&OsStr> {
    let path = path.to_str().map_or(path, |value| {
        // Foundation's whitespace-and-newline set also contains zero-width space.
        OsStr::new(value.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}'))
    });
    (!path.is_empty()).then_some(path)
}

pub struct Client {
    stream: Option<UnixStream>,
    next_id: u64,
    options: ClientOptions,
}
impl Client {
    pub fn connect() -> Result<Self> {
        Self::connect_to(default_socket_path()?)
    }
    pub fn connect_to(path: impl AsRef<Path>) -> Result<Self> {
        Self::connect_with_options(path, ClientOptions::default())
    }
    /// Connects to the endpoint configured by a service application's Info.plist.
    /// The application must already be running; this does not launch it.
    pub fn connect_to_service_bundle(bundle: impl AsRef<Path>) -> Result<Self> {
        Self::connect_to(service_bundle_socket_path(bundle)?)
    }
    /// The timeout bounds handshake and RPC I/O. Unix socket connection setup
    /// uses the operating system's blocking `connect`, without startup retries.
    pub fn connect_with_options(path: impl AsRef<Path>, options: ClientOptions) -> Result<Self> {
        validate_timeout(options.timeout)?;
        nonempty(&options.api_version, "api_version")?;
        let stream = unix_socket::connect(path.as_ref())?;
        Self::from_stream(stream, options)
    }
    fn from_stream(stream: UnixStream, options: ClientOptions) -> Result<Self> {
        stream.set_nonblocking(true)?;
        let mut client = Self {
            stream: Some(stream),
            next_id: 1,
            options,
        };
        let result = client.call(
            "ping",
            json!({"clientApiVersion": client.options.api_version}),
            client.options.timeout,
        )?;
        let server = result
            .get("serverApiVersion")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Protocol("ping omitted serverApiVersion".into()))?;
        if server != client.options.api_version {
            return Err(Error::VersionMismatch {
                client: client.options.api_version.clone(),
                server: server.into(),
            });
        }
        Ok(client)
    }
    pub fn is_closed(&self) -> bool {
        self.stream.is_none()
    }
    pub fn close(&mut self) {
        if let Some(stream) = self.stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }
    /// Send any service request type; results can be deserialized into your
    /// own structs or `serde_json::Value`. Unsupported service routes return the
    /// native error code instead of being emulated by this library.
    pub fn request<R: DeserializeOwned>(
        &mut self,
        request_type: &str,
        request: impl Serialize,
    ) -> Result<R> {
        self.request_with_options(request_type, request, &RequestOptions::default())
    }
    pub fn request_with_options<R: DeserializeOwned>(
        &mut self,
        request_type: &str,
        request: impl Serialize,
        options: &RequestOptions,
    ) -> Result<R> {
        self.request_with_files(request_type, request, options, &[])
    }

    /// Sends a request with borrowed file descriptors in caller order.
    /// At most 254 descriptors may accompany the frame on macOS. The caller retains its
    /// handles; the receiver gets kernel duplicates sharing their file offsets.
    /// A transport failure never retries a request that may have taken effect.
    pub fn request_with_files<R: DeserializeOwned>(
        &mut self,
        request_type: &str,
        request: impl Serialize,
        options: &RequestOptions,
        files: &[BorrowedFd<'_>],
    ) -> Result<R> {
        nonempty(request_type, "request_type")?;
        if files.len() > MAX_FRAME_FILES {
            return Err(Error::InvalidInput(
                "request has more than 254 attachment files".into(),
            ));
        }
        let timeout = options.timeout.unwrap_or(self.options.timeout);
        validate_timeout(timeout)?;
        let deadline = SystemTime::now()
            .checked_add(timeout)
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .ok_or_else(|| Error::InvalidInput("request deadline overflow".into()))?
            .as_millis();
        let deadline = i64::try_from(deadline)
            .map_err(|_| Error::InvalidInput("request deadline overflow".into()))?;
        let mut params = json!({
            "clientApiVersion": self.options.api_version,
            "requestType": request_type,
            "request": serde_json::to_value(request)?,
            "deadlineUnixMilliseconds": deadline,
        });
        if let Some(metadata) = options
            .agent_metadata
            .as_ref()
            .or(self.options.agent_metadata.as_ref())
        {
            params["agentTurnMetadata"] = metadata.clone();
        }
        let value = self.call_with_files("request", params, timeout, files)?;
        // A typed result mismatch does not corrupt the already-consumed frame.
        serde_json::from_value(value).map_err(Error::Json)
    }
    fn call(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value> {
        self.call_with_files(method, params, timeout, &[])
    }

    fn call_with_files(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
        files: &[BorrowedFd<'_>],
    ) -> Result<Value> {
        if self.is_closed() {
            return Err(Error::Closed);
        }
        let id = self.next_id;
        if id > i64::MAX as u64 {
            return Err(Error::InvalidInput("request ID exhausted".into()));
        }
        let body =
            serde_json::to_vec(&json!({"id":id,"jsonrpc":"2.0","method":method,"params":params}))?;
        if body.len() > MAX_FRAME_BYTES {
            return Err(Error::InvalidInput("request frame exceeds 8 MiB".into()));
        }
        self.next_id += 1;
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or_else(|| Error::InvalidInput("request timeout overflow".into()))?;
        let result = (|| {
            let stream = self.stream.as_mut().ok_or(Error::Closed)?;
            let header = (body.len() as u32).to_le_bytes();
            if files.is_empty() {
                write_all(stream, &header, deadline)?;
            } else {
                write_header_with_files(stream, &header, files, deadline)?;
            }
            write_all(stream, &body, deadline)?;
            let mut header = [0; 4];
            read_exact(stream, &mut header, deadline)?;
            let size = u32::from_le_bytes(header) as usize;
            if size > MAX_FRAME_BYTES {
                return Err(Error::Protocol("response frame exceeds 8 MiB".into()));
            }
            let mut response = vec![0; size];
            read_exact(stream, &mut response, deadline)?;
            let native_json::NativeValue(value) = serde_json::from_slice(&response)?;
            if value.get("jsonrpc").and_then(Value::as_str) != Some("2.0")
                || value.get("id").and_then(Value::as_u64) != Some(id)
            {
                return Err(Error::Protocol(
                    "JSON-RPC version or request ID mismatch".into(),
                ));
            }
            match (value.get("result"), value.get("error")) {
                (Some(value), None) => Ok(value.clone()),
                (None, Some(value)) => {
                    if !value.is_object() {
                        return Err(Error::Protocol("malformed remote error".into()));
                    }
                    let error = serde_json::from_value(value.clone())
                        .map_err(|_| Error::Protocol("malformed remote error".into()))?;
                    Err(Error::Remote(error))
                }
                _ => Err(Error::Protocol(
                    "expected exactly one of result/error".into(),
                )),
            }
        })();
        if result
            .as_ref()
            .is_err_and(|e| !matches!(e, Error::Remote(_)))
        {
            self.close();
        }
        result
    }

    pub fn list_apps(&mut self) -> Result<Vec<AppInfo>> {
        self.request("ComputerUseIPCListAppsRequest", json!({}))
    }
    pub fn app_policy(&mut self, app: &str) -> Result<Value> {
        self.app_request("AppPolicy", app)
    }
    pub fn start_app(&mut self, app: &str) -> Result<Value> {
        self.app_request("AppStart", app)
    }
    pub fn stop_app(&mut self, app: &str) -> Result<Value> {
        self.app_request("AppStop", app)
    }
    fn app_request(&mut self, kind: &str, app: &str) -> Result<Value> {
        nonempty(app, "app")?;
        self.request(&format!("ComputerUseIPC{kind}Request"), json!({"app":app}))
    }
    pub fn modify_app(&mut self, app: &str, modification: AppModification) -> Result<Value> {
        nonempty(app, "app")?;
        let operation = match modification {
            AppModification::Activate => "activate",
            AppModification::Deactivate => "deactivate",
        };
        self.request(
            "ComputerUseIPCAppModifyRequest",
            json!({"app":app,"modification":{operation:{}}}),
        )
    }
    pub fn frontmost_window(&mut self) -> Result<Option<Value>> {
        self.request("ComputerUseIPCFrontmostWindowRequest", json!({}))
    }
    /// Returns the foreground application and window title, when available.
    pub fn frontmost_window_typed(&mut self) -> Result<Option<FrontmostWindow>> {
        self.request("ComputerUseIPCFrontmostWindowRequest", json!({}))
    }
    pub fn appSnapshot(&mut self, app: &str, disable_diff: bool) -> Result<Value> {
        nonempty(app, "app")?;
        self.request(
            "ComputerUseIPCAppGetAppSnapshotRequest",
            json!({"app":app,"disableDiff":disable_diff}),
        )
    }
    /// Reads the required accessibility state and application-specific guidance.
    /// `disable_diff` uses the same wire flag as [`Client::appSnapshot`].
    pub fn app_snapshot_typed(&mut self, app: &str, disable_diff: bool) -> Result<AppSnapshotResult> {
        nonempty(app, "app")?;
        self.request(
            "ComputerUseIPCAppGetAppSnapshotRequest",
            json!({"app":app,"disableDiff":disable_diff}),
        )
    }
    /// Capture options remain extensible; see the AppStartCapture wire contract.
    /// The service owns requestID lifetime and polling semantics.
    pub fn start_capture(&mut self, app: &str, request_id: &str, options: Value) -> Result<Value> {
        nonempty(app, "app")?;
        nonempty(request_id, "request_id")?;
        let mut request = options
            .as_object()
            .cloned()
            .ok_or_else(|| Error::InvalidInput("capture options must be an object".into()))?;
        request.insert("app".into(), app.into());
        request.remove("requestID");
        request.insert("requestId".into(), request_id.into());
        if let Some(permission_id) = request.remove("permissionRequestID") {
            request
                .entry("permissionRequestId")
                .or_insert(permission_id);
        }
        self.request(capture::START_REQUEST, request)
    }
    pub fn next_capture_update(&mut self, request_id: &str) -> Result<Value> {
        nonempty(request_id, "request_id")?;
        self.request(capture::NEXT_REQUEST, json!({"requestId":request_id}))
    }
    pub fn perform_action(&mut self, app: &str, action: Action) -> Result<Value> {
        nonempty(app, "app")?;
        action.validate()?;
        self.request(
            "ComputerUseIPCAppPerformActionRequest",
            json!({"app":app,"action":action}),
        )
    }
    /// Performs one action and validates its native acknowledgement.
    /// The acknowledgement's appSnapshot is optional; use [`Client::app_snapshot_typed`]
    /// when a required fresh observation is needed.
    pub fn perform_action_typed(&mut self, app: &str, action: Action) -> Result<ActionResult> {
        let value = self.perform_action(app, action)?;
        serde_json::from_value(value).map_err(Error::Json)
    }
    /// Performs the action, then requests a fresh accessibility state and image.
    /// These are two requests. A capture error can occur after input was delivered;
    /// this method never retries the action.
    pub fn perform_action_with_app_snapshot(
        &mut self,
        app: &str,
        action: Action,
    ) -> Result<AppSnapshotResult> {
        self.perform_action_typed(app, action)?;
        self.app_snapshot_typed(app, true)
    }

    /// Ends an agent turn. If the user stopped Computer Use during the turn, the
    /// apps it used stay stopped until this call; the next turn can use them again.
    ///
    /// `session_id` and `turn_id` are the values sent as `session_id`/`turn_id`
    /// in the request metadata ([`TurnMetadata`]). Only the session's latest turn
    /// releases a stop; `None` ends the whole session.
    pub fn turn_ended(&mut self, session_id: &str, turn_id: Option<&str>) -> Result<()> {
        // The wire request names these fields threadID and turnID.
        let mut request = json!({"threadID": session_id});
        if let Some(turn_id) = turn_id {
            request["turnID"] = json!(turn_id);
        }
        self.request_empty_response("ComputerUseIPCTurnEndedRequest", request)
    }

    // The native ComputerUseIPCEmptyResponse ignores any valid JSON value.
    // Decode only after the shared transport has checked framing and RPC errors.
    fn request_empty_response(&mut self, request_type: &str, request: impl Serialize) -> Result<()> {
        self.request::<serde::de::IgnoredAny>(request_type, request)
            .map(|_| ())
    }

    pub fn start_event_stream(&mut self) -> Result<Value> {
        self.request("ComputerUseIPCEventStreamStartRequest", json!({}))
    }
    pub fn event_stream_status(&mut self) -> Result<Value> {
        self.request("ComputerUseIPCEventStreamStatusRequest", json!({}))
    }
    pub fn stop_event_stream(&mut self, reason: EventStreamEndReason) -> Result<Value> {
        self.request(
            "ComputerUseIPCEventStreamStopRequest",
            json!({"reason":reason}),
        )
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Debug, Clone, Copy)]
pub enum AppModification {
    Activate,
    Deactivate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventStreamEndReason {
    ToolStopped,
    DebugUiStopped,
    RecordingControlsStopped,
    RecordingControlsCancelled,
    MaxDuration,
    ServiceTerminated,
}

/// Native conversation keys. Explicit empty strings, zero timestamps and false
/// flags retain their presence on the wire.
#[derive(Debug, Default, Clone, Serialize)]
pub struct TurnMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_started_at_unix_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_input_requested_during_turn: Option<bool>,
}
impl From<TurnMetadata> for Value {
    fn from(metadata: TurnMetadata) -> Self {
        serde_json::to_value(metadata).expect("strings, integers and bools are JSON serializable")
    }
}

native_response_object! {
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub display_name: String,
    pub bundle_identifier: String,
    pub is_running: bool,
    pub app_path: Option<String>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}
}
impl AppInfo {
    /// Older services may omit the foreground flag.
    pub fn is_frontmost(&self) -> Option<bool> {
        self.extra.get("isFrontmost").and_then(Value::as_bool)
    }

    /// Seconds since 2001-01-01 UTC, when Spotlight supplies a date.
    pub fn last_used_date(&self) -> Option<f64> {
        self.extra.get("lastUsedDate").and_then(Value::as_f64)
    }

    pub fn use_count(&self) -> Option<i64> {
        self.extra.get("useCount").and_then(Value::as_i64)
    }
}

native_response_object! {
#[derive(Debug, Clone, Serialize, Deserialize)]
/// An action result and the state observed immediately after the action.
pub struct ActionResult {
    pub app: ActionApp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub appSnapshot: Option<ActionAppSnapshot>,
}
}

native_response_object! {
#[derive(Debug, Clone, Serialize, Deserialize)]
/// A required observation plus optional instructions provided by the app.
/// This is the response of GetAppSnapshot, distinct from an action acknowledgement.
#[serde(rename_all = "camelCase")]
pub struct AppSnapshotResult {
    pub app: ActionApp,
    pub appSnapshot: ActionAppSnapshot,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_specific_instructions: Option<String>,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionApp {
    pub pid: i32,
    pub bundle_identifier: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_path: Option<String>,
}
impl<'de> Deserialize<'de> for ActionApp {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            #[serde(deserialize_with = "core::deserialize_i32")]
            pid: i32,
            bundle_identifier: String,
            app_path: Option<String>,
        }
        let fields: Fields = core::object_fields(deserializer)?;
        Ok(Self { pid: fields.pid, bundle_identifier: fields.bundle_identifier, app_path: fields.app_path })
    }
}

native_response_object! {
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionAppSnapshot {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<ActionScreenshot>,
}
}

native_response_object! {
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionScreenshot {
    #[cfg_attr(target_os = "macos", serde(deserialize_with = "crate::foundation::deserialize_url"))]
    pub url: String,
    pub mime_type: String,
}
}

fn nonempty(value: &str, name: &str) -> Result<()> {
    if value.trim().is_empty() {
        Err(Error::InvalidInput(format!("{name} must not be empty")))
    } else {
        Ok(())
    }
}
fn validate_timeout(timeout: Duration) -> Result<()> {
    if timeout.is_zero() || timeout > Duration::from_secs(86400) {
        return Err(Error::InvalidInput(
            "timeout must be greater than zero and at most 24 hours".into(),
        ));
    }
    Ok(())
}
fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "CUA request deadline exceeded"))
}
fn write_all(stream: &mut UnixStream, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        wait_ready(stream, libc::POLLOUT, deadline)?;
        match stream.write(bytes) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "CUA socket closed during write",
                ))
            }
            Ok(count) => bytes = &bytes[count..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn write_header_with_files(
    stream: &mut UnixStream,
    header: &[u8; 4],
    files: &[BorrowedFd<'_>],
    deadline: Instant,
) -> io::Result<()> {
    let payload_size = (files.len() * std::mem::size_of::<libc::c_int>()) as libc::c_uint;
    // SAFETY: the control buffer has native word alignment and enough room for
    // one SCM_RIGHTS message. Borrowed descriptors live until sendmsg returns.
    unsafe {
        let control_size = libc::CMSG_SPACE(payload_size) as usize;
        let mut control = vec![0usize; control_size.div_ceil(std::mem::size_of::<usize>())];
        let mut data = libc::iovec {
            iov_base: header.as_ptr().cast_mut().cast(),
            iov_len: header.len(),
        };
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_iov = &mut data;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = control_size as _;
        let ancillary = libc::CMSG_FIRSTHDR(&message);
        if ancillary.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid descriptor control buffer",
            ));
        }
        (*ancillary).cmsg_len = libc::CMSG_LEN(payload_size) as _;
        (*ancillary).cmsg_level = libc::SOL_SOCKET;
        (*ancillary).cmsg_type = libc::SCM_RIGHTS;
        let descriptors = libc::CMSG_DATA(ancillary).cast::<libc::c_int>();
        for (index, file) in files.iter().enumerate() {
            descriptors.add(index).write_unaligned(file.as_raw_fd());
        }
        loop {
            wait_ready(stream, libc::POLLOUT, deadline)?;
            let written = libc::sendmsg(stream.as_raw_fd(), &message, libc::MSG_NOSIGNAL);
            if written > 0 {
                // Any successful byte also transfers the descriptors exactly once.
                return write_all(stream, &header[written as usize..], deadline);
            }
            if written == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "CUA socket closed during descriptor transfer",
                ));
            }
            let error = io::Error::last_os_error();
            if !matches!(
                error.kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
            ) {
                return Err(error);
            }
        }
    }
}
fn read_exact(stream: &mut UnixStream, mut bytes: &mut [u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        wait_ready(stream, libc::POLLIN, deadline)?;
        match stream.read(bytes) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "CUA socket closed before complete response",
                ))
            }
            Ok(count) => bytes = &mut bytes[count..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

// Polling a nonblocking socket preserves a whole-frame deadline without
// resetting SO_RCVTIMEO after EOF (which fails on Darwin with buffered data).
fn wait_ready(stream: &UnixStream, events: libc::c_short, deadline: Instant) -> io::Result<()> {
    loop {
        let duration = remaining(deadline)?;
        let millis = duration
            .as_millis()
            .saturating_add(u128::from(duration.subsec_nanos() % 1_000_000 != 0));
        let millis = millis.min(libc::c_int::MAX as u128) as libc::c_int;
        let mut descriptor = libc::pollfd {
            fd: stream.as_raw_fd(),
            events,
            revents: 0,
        };
        // SAFETY: descriptor is initialized, lives for this call, and the stream
        // owns its fd throughout the synchronous poll. Exactly one entry exists.
        let status = unsafe { libc::poll(&mut descriptor, 1, millis) };
        if status < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if status == 0 {
            continue;
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "CUA socket descriptor is invalid",
            ));
        }
        if descriptor.revents & (events | libc::POLLHUP | libc::POLLERR) != 0 {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests;
