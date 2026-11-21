use crate::{nonempty, ActionApp, ActionScreenshot, Client, Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;

pub(crate) const START_REQUEST: &str = "ComputerUseIPCAppStartCaptureRequest";
pub(crate) const NEXT_REQUEST: &str = "ComputerUseIPCAppNextCaptureUpdateRequest";

/// Numeric version of the capture stream. Future versions keep their raw value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct CaptureVersion(pub i64);

impl CaptureVersion {
    pub const INITIAL: Self = Self(1);
    pub const RELIABLE_FINAL_FRAME: Self = Self(2);
}

#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureOptions {
    /// Defaults to the capture request ID on the service.
    #[serde(
        rename = "permissionRequestId",
        skip_serializing_if = "Option::is_none"
    )]
    pub permission_request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_target: Option<CaptureAnimationTarget>,
    /// The service defaults to [`CaptureVersion::INITIAL`] when omitted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<CaptureVersion>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct CaptureRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl CaptureRect {
    fn is_finite(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .into_iter()
            .all(f64::is_finite)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct CaptureColor {
    pub red: i64,
    pub green: i64,
    pub blue: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureDisplay {
    pub id: i64,
    pub bounds: CaptureRect,
    pub work_area: CaptureRect,
    pub scale_factor: f64,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapturePresentationStyle {
    #[default]
    Standard,
    QuickChat,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureAnimationTarget {
    pub destination_frame: CaptureRect,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination_corner_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination_background_color: Option<CaptureColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination_primary_text_color: Option<CaptureColor>,
    pub presentation_style: CapturePresentationStyle,
    pub agent_display: CaptureDisplay,
}

impl CaptureAnimationTarget {
    fn validate(&self) -> Result<()> {
        if !self.destination_frame.is_finite()
            || !self.agent_display.bounds.is_finite()
            || !self.agent_display.work_area.is_finite()
            || !self.agent_display.scale_factor.is_finite()
            || self
                .destination_corner_radius
                .is_some_and(|radius| !radius.is_finite())
        {
            return Err(Error::InvalidInput(
                "capture animation coordinates and scale must be finite".into(),
            ));
        }
        Ok(())
    }
}

native_tagged_response! { "CaptureStartResponse";
#[serde(
    tag = "result",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum CaptureStartResponse {
    Started {
        #[serde(skip_serializing_if = "Option::is_none")]
        animation_duration: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_snapshot_height: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_spring_response: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_spring_damping_fraction: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        permission_grant_state: Option<CapturePermissionState>,
    },
    #[serde(rename = "appshot_permissions_abandoned")]
    PermissionsAbandoned {
        #[serde(skip_serializing_if = "Option::is_none")]
        permission_grant_state: Option<CapturePermissionState>,
        #[serde(skip_serializing_if = "Option::is_none")]
        animation_duration: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_snapshot_height: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_spring_response: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transition_spring_damping_fraction: Option<f64>,
    },
}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapturePermissionState {
    NoneGranted,
    AccessibilityGranted,
    ScreenRecordingGranted,
    BothGranted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptureUpdateKind {
    AxText,
    Completed,
    Failed,
    Metadata,
    Screenshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureFailureReason {
    BlockedByPolicy,
    ScreenshotCaptureFailed,
    UnknownCaptureFailed,
}

native_response_object! {
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureUpdate {
    #[serde(rename = "type")]
    pub kind: CaptureUpdateKind,
    pub app: ActionApp,
    pub text: Option<String>,
    pub screenshot: Option<ActionScreenshot>,
    /// File URL for the animation frame. A screenshot update can carry this
    /// URL in place of `screenshot`. A completed update can carry it again.
    #[serde(rename = "transitionSnapshotURL")]
    #[cfg_attr(target_os = "macos", serde(default, deserialize_with = "crate::foundation::deserialize_optional_url"))]
    pub transition_snapshot_url: Option<String>,
    pub failure_reason: Option<CaptureFailureReason>,
}
}

impl CaptureUpdate {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self.kind,
            CaptureUpdateKind::Completed | CaptureUpdateKind::Failed
        )
    }
}

impl Client {
    /// Starts a capture using the typed request and response.
    /// Only [`CaptureStartResponse::Started`] creates a stream to read.
    pub fn start_capture_typed(
        &mut self,
        app: &str,
        request_id: &str,
        options: &CaptureOptions,
    ) -> Result<CaptureStartResponse> {
        nonempty(app, "app")?;
        nonempty(request_id, "request_id")?;
        if let Some(target) = &options.animation_target {
            target.validate()?;
        }
        #[derive(Serialize)]
        struct Request<'a> {
            app: &'a str,
            #[serde(rename = "requestId")]
            request_id: &'a str,
            #[serde(flatten)]
            options: &'a CaptureOptions,
        }
        self.request(
            START_REQUEST,
            Request {
                app,
                request_id,
                options,
            },
        )
    }

    /// Reads one stage. Stop after a completed or failed update.
    pub fn next_capture_update_typed(&mut self, request_id: &str) -> Result<CaptureUpdate> {
        nonempty(request_id, "request_id")?;
        self.request(NEXT_REQUEST, json!({"requestId": request_id}))
    }
}
