use crate::{Client, Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct CalendarSource {
    pub id: String,
    pub title: String,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarInfo {
    pub id: String,
    pub title: String,
    pub source: CalendarSource,
    pub allows_content_modifications: bool,
    pub is_default: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventId {
    pub identifier: String,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub start_date: f64,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub end_date: f64,
}
}

native_response_object! {
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarAttendee {
    pub email: Option<String>,
    pub name: Option<String>,
    pub is_current_user: Option<bool>,
}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CalendarParticipantStatus {
    Unknown,
    Pending,
    Accepted,
    Declined,
    Tentative,
    Delegated,
    Completed,
    InProcess,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CalendarEventSpan {
    ThisEvent,
    FutureEvents,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: CalendarEventId,
    #[serde(rename = "calendarID")]
    pub calendar_id: String,
    pub title: Option<String>,
    pub is_all_day: bool,
    pub location: Option<String>,
    pub notes: Option<String>,
    #[cfg_attr(target_os = "macos", serde(default, deserialize_with = "crate::foundation::deserialize_optional_url"))]
    pub url: Option<String>,
    pub attendees: Vec<CalendarAttendee>,
    #[serde(rename = "recurrenceRFC2445")]
    pub recurrence_rfc2445: Option<String>,
    pub is_canceled: bool,
    pub current_user_participant_status: Option<CalendarParticipantStatus>,
    pub is_editable: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventsPage {
    pub events: Vec<CalendarEvent>,
    pub next_cursor: Option<String>,
}
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventsQuery {
    pub start_date: f64,
    pub end_date: f64,
    #[serde(rename = "calendarIDs")]
    pub calendar_ids: Vec<String>,
    pub limit: i64,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventDetails {
    #[serde(rename = "calendarID")]
    pub calendar_id: Option<String>,
    pub end_date: Option<f64>,
    pub location: Option<String>,
    pub notes: Option<String>,
    /// For updates, an empty string clears the URL.
    pub url: Option<String>,
    #[serde(rename = "recurrenceRFC2445")]
    pub recurrence_rfc2445: Option<String>,
    /// For updates, an empty list clears the attendees.
    pub attendees: Option<Vec<CalendarAttendee>>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventCreation {
    pub title: String,
    pub start_date: f64,
    pub is_all_day: bool,
    #[serde(flatten)]
    pub details: CalendarEventDetails,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventPatch {
    pub title: Option<String>,
    pub start_date: Option<f64>,
    pub is_all_day: Option<bool>,
    #[serde(flatten)]
    pub details: CalendarEventDetails,
}

impl Client {
    pub fn list_calendars(&mut self) -> Result<Vec<CalendarInfo>> {
        self.request("ComputerUseIPCCalendarListCalendarsRequest", json!({}))
    }

    pub fn list_calendar_events(
        &mut self,
        query: &CalendarEventsQuery,
    ) -> Result<CalendarEventsPage> {
        require_finite_dates([query.start_date, query.end_date])?;
        self.request(
            "ComputerUseIPCCalendarListEventsRequest",
            serde_json::to_value(query)?,
        )
    }

    pub fn get_calendar_event(&mut self, id: &CalendarEventId) -> Result<CalendarEvent> {
        require_finite_dates([id.start_date, id.end_date])?;
        self.request("ComputerUseIPCCalendarGetEventRequest", json!({"id":id}))
    }

    pub fn create_calendar_event(
        &mut self,
        event: &CalendarEventCreation,
    ) -> Result<CalendarEvent> {
        require_finite_dates(
            [Some(event.start_date), event.details.end_date]
                .into_iter()
                .flatten(),
        )?;
        self.request(
            "ComputerUseIPCCalendarCreateEventRequest",
            serde_json::to_value(event)?,
        )
    }

    pub fn update_calendar_event(
        &mut self,
        id: &CalendarEventId,
        span: CalendarEventSpan,
        patch: &CalendarEventPatch,
    ) -> Result<CalendarEvent> {
        require_finite_dates(
            [
                Some(id.start_date),
                Some(id.end_date),
                patch.start_date,
                patch.details.end_date,
            ]
            .into_iter()
            .flatten(),
        )?;
        #[derive(Serialize)]
        struct Update<'a> {
            id: &'a CalendarEventId,
            span: CalendarEventSpan,
            #[serde(flatten)]
            patch: &'a CalendarEventPatch,
        }
        self.request(
            "ComputerUseIPCCalendarUpdateEventRequest",
            serde_json::to_value(Update { id, span, patch })?,
        )
    }

    pub fn delete_calendar_event(
        &mut self,
        id: &CalendarEventId,
        span: CalendarEventSpan,
    ) -> Result<()> {
        require_finite_dates([id.start_date, id.end_date])?;
        self.request_empty_response(
            "ComputerUseIPCCalendarDeleteEventRequest",
            json!({"id":id,"span":span}),
        )
    }
}

fn require_finite_dates(dates: impl IntoIterator<Item = f64>) -> Result<()> {
    if dates.into_iter().all(f64::is_finite) {
        Ok(())
    } else {
        Err(Error::InvalidInput("Calendar dates must be finite".into()))
    }
}
