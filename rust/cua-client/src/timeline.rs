use crate::{Client, Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimelineState {
    Stopped,
    Running,
    Paused,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuState {
    pub computer_use: StatusMenuComputerUse,
    pub computer_history: StatusMenuComputerHistory,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuComputerUse {
    pub active_applications: Vec<StatusMenuApplication>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuApplication {
    pub id: String,
    pub name: String,
    pub bundle_identifier: Option<String>,
    #[serde(rename = "bundleURL")]
    pub bundle_url: Option<String>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuComputerHistory {
    pub state: TimelineState,
    pub can_clear_history: StatusMenuHistoryAvailability,
    pub recent_applications: Vec<StatusMenuRecentApplication>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuHistoryAvailability {
    pub last_ten_minutes: bool,
    pub last_hour: bool,
    pub last_day: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuRecentApplication {
    #[serde(flatten)]
    pub application: StatusMenuApplication,
    pub is_excluded: bool,
    pub last_session: StatusMenuApplicationSession,
    pub domains: Vec<StatusMenuDomain>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuApplicationSession {
    /// ISO 8601 timestamp in UTC.
    pub started_at: String,
    /// ISO 8601 timestamp in UTC.
    pub ended_at: Option<String>,
    pub can_clear_history: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMenuDomain {
    pub domain: String,
    pub is_excluded: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineStatus {
    pub state: TimelineState,
    pub event_stream_root_path: Option<String>,
    pub current_segment_events_path: Option<String>,
    pub current_segment_metadata_path: Option<String>,
    pub suppressed_events_path: Option<String>,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub started_at: Option<f64>,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub ended_at: Option<f64>,
}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TimelinePauseDuration {
    ThirtyMinutes,
    OneHour,
    UntilTomorrow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimelineObservationBehavior {
    Observe,
    DoNotObserve,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "scope", rename_all = "snake_case")]
pub enum TimelineObservationRule {
    App {
        #[serde(rename = "bundleID")]
        bundle_id: String,
    },
    Url {
        #[serde(rename = "urlDomain")]
        url_domain: String,
    },
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineObservationSettings {
    pub default_application_behavior: TimelineObservationBehavior,
    #[serde(rename = "defaultURLBehavior")]
    pub default_url_behavior: TimelineObservationBehavior,
    pub allowlist: Vec<TimelineObservationRule>,
    pub blocklist: Vec<TimelineObservationRule>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineSettings {
    pub observation: TimelineObservationSettings,
}
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct TimelineHistoryInterval {
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub start: f64,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub end: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(tag = "scope", rename_all = "snake_case")]
pub enum TimelineHistoryScope {
    ApplicationSession { interval: TimelineHistoryInterval },
    LastTenMinutes,
    LastHour,
    LastDay,
    All,
    Interval { interval: TimelineHistoryInterval },
}

impl Client {
    pub fn status_menu(&mut self) -> Result<StatusMenuState> {
        self.request("ComputerUseIPCStatusItemMenuStateRequest", json!({}))
    }

    pub fn start_timeline(&mut self) -> Result<TimelineStatus> {
        self.request("ComputerUseIPCTimelineStartRequest", json!({}))
    }

    pub fn timeline_status(&mut self) -> Result<TimelineStatus> {
        self.request("ComputerUseIPCTimelineStatusRequest", json!({}))
    }

    pub fn stop_timeline(&mut self) -> Result<TimelineStatus> {
        self.request("ComputerUseIPCTimelineStopRequest", json!({}))
    }

    pub fn pause_timeline(
        &mut self,
        duration: Option<TimelinePauseDuration>,
    ) -> Result<TimelineStatus> {
        let request = match duration {
            Some(duration) => json!({ "duration": duration }),
            None => json!({}),
        };
        self.request("ComputerUseIPCTimelinePauseRequest", request)
    }

    pub fn resume_timeline(&mut self) -> Result<TimelineStatus> {
        self.request("ComputerUseIPCTimelineResumeRequest", json!({}))
    }

    pub fn timeline_settings(&mut self) -> Result<TimelineSettings> {
        self.request("ComputerUseIPCTimelineGetSettingsRequest", json!({}))
    }

    pub fn update_timeline_settings(
        &mut self,
        settings: &TimelineSettings,
    ) -> Result<TimelineSettings> {
        self.request(
            "ComputerUseIPCTimelineUpdateSettingsRequest",
            json!({ "settings": settings }),
        )
    }

    pub fn update_timeline_observation_policy(
        &mut self,
        target: &TimelineObservationRule,
        observe: bool,
    ) -> Result<TimelineSettings> {
        self.request(
            "ComputerUseIPCTimelineUpdateObservationPolicyRequest",
            json!({ "target": target, "observe": observe }),
        )
    }

    pub fn clear_timeline_history(
        &mut self,
        scope: TimelineHistoryScope,
    ) -> Result<TimelineStatus> {
        if let TimelineHistoryScope::ApplicationSession { interval }
        | TimelineHistoryScope::Interval { interval } = scope
        {
            if !interval.start.is_finite()
                || !interval.end.is_finite()
                || interval.start >= interval.end
            {
                return Err(Error::InvalidInput(
                    "Timeline history interval requires finite dates with start before end".into(),
                ));
            }
        }
        let request: Value = serde_json::to_value(scope)?;
        self.request("ComputerUseIPCTimelineClearHistoryRequest", request)
    }
}
