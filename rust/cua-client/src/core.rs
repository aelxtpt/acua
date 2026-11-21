use crate::{ActionApp, AppModification, Client, EventStreamEndReason, Result};
use serde::{de::{DeserializeOwned, Error as _}, Deserialize, Deserializer, Serialize};
use serde_json::Value;

pub(crate) fn object_fields<'de, D: Deserializer<'de>, T: DeserializeOwned>(deserializer: D) -> std::result::Result<T, D::Error> {
    let crate::native_json::NativeValue(value) = crate::native_json::NativeValue::deserialize(deserializer)?;
    if !value.is_object() {
        return Err(D::Error::custom("native response requires a JSON object"));
    }
    serde_json::from_value(value).map_err(D::Error::custom)
}

pub(crate) fn deserialize_i64<'de, D: Deserializer<'de>>(deserializer: D) -> std::result::Result<i64, D::Error> {
    let value = Value::deserialize(deserializer)?;
    if let Some(number) = value.as_i64() { return Ok(number); }
    if let Some(number) = value.as_u64() {
        return i64::try_from(number).map_err(D::Error::custom);
    }
    // The service accepts integral floating spellings. Floating conversion
    // rejects both 64-bit boundary doubles; integer spellings retain full range.
    if let Some(number) = value.as_f64() {
        if number.is_finite() && number.fract() == 0.0 && number > i64::MIN as f64 && number < 9_223_372_036_854_775_808.0 {
            return Ok(number as i64);
        }
    }
    Err(D::Error::custom("native signed integer is out of range or non-integral"))
}

pub(crate) fn deserialize_optional_i64<'de,D:Deserializer<'de>>(deserializer:D)->std::result::Result<Option<i64>,D::Error> {
    Option::<Value>::deserialize(deserializer)?.map(|value|deserialize_i64(value).map_err(D::Error::custom)).transpose()
}

pub(crate) fn deserialize_i32<'de, D: Deserializer<'de>>(deserializer: D) -> std::result::Result<i32, D::Error> {
    i32::try_from(deserialize_i64(deserializer)?).map_err(D::Error::custom)
}

// Swift's keyed Codable structs reject arrays, including arrays that happen
// to match the field order. Keep the object check on nested public models too.
macro_rules! native_object {
    ($(#[$meta:meta])* pub struct $name:ident { $($(#[$attr:meta])* pub $field:ident: $ty:ty),* $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Serialize)]
        #[serde(rename_all = "camelCase")]
        pub struct $name { $($(#[$attr])* pub $field: $ty),* }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Fields { $($(#[$attr])* $field: $ty),* }
                let fields: Fields = object_fields(deserializer)?;
                Ok(Self { $($field: fields.$field),* })
            }
        }
    }
}

native_object! {
    /// Automation-session state. `active` is independent of OS window activation.
    pub struct AppState {
        pub active: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub current_app: Option<ActionApp>,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppPolicyDecision { Allowed, Denied, Forbidden }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppTargetRisk { Low, High }

native_object! {
    pub struct AppPolicyTarget {
        pub bundle_identifier: String,
        pub display_name: String,
        pub app_path: String,
        pub risk: AppTargetRisk,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub warning_subtitle: Option<String>,
    }
}

native_object! {
    pub struct AppPolicyResult {
        pub decision: AppPolicyDecision,
        pub target: AppPolicyTarget,
        pub allow_persistent_approval: bool,
    }
}

native_object! {
    pub struct EventStreamStatus {
        pub is_recording: bool,
        #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
        pub session_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub session_directory_path: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub events_path: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub metadata_path: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub suppressed_events_path: Option<String>,
        /// Seconds since 2001-01-01 00:00:00 UTC.
        #[serde(skip_serializing_if = "Option::is_none")]
        pub started_at: Option<f64>,
        /// Seconds since 2001-01-01 00:00:00 UTC.
        #[serde(skip_serializing_if = "Option::is_none")]
        pub ended_at: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub end_reason: Option<EventStreamEndReason>,
        #[serde(deserialize_with = "deserialize_i64")]
        pub max_duration_seconds: i64,
    }
}

impl Client {
    pub fn app_policy_typed(&mut self, app: &str) -> Result<AppPolicyResult> {
        serde_json::from_value(self.app_policy(app)?).map_err(crate::Error::Json)
    }
    pub fn start_app_typed(&mut self, app: &str) -> Result<AppState> {
        serde_json::from_value(self.start_app(app)?).map_err(crate::Error::Json)
    }
    pub fn stop_app_typed(&mut self, app: &str) -> Result<AppState> {
        serde_json::from_value(self.stop_app(app)?).map_err(crate::Error::Json)
    }
    pub fn modify_app_typed(&mut self, app: &str, modification: AppModification) -> Result<AppState> {
        serde_json::from_value(self.modify_app(app, modification)?).map_err(crate::Error::Json)
    }
    pub fn start_event_stream_typed(&mut self) -> Result<EventStreamStatus> {
        serde_json::from_value(self.start_event_stream()?).map_err(crate::Error::Json)
    }
    pub fn event_stream_status_typed(&mut self) -> Result<EventStreamStatus> {
        serde_json::from_value(self.event_stream_status()?).map_err(crate::Error::Json)
    }
    pub fn stop_event_stream_typed(&mut self, reason: EventStreamEndReason) -> Result<EventStreamStatus> {
        serde_json::from_value(self.stop_event_stream(reason)?).map_err(crate::Error::Json)
    }
}

// Independently implement the observable Foundation Data Codable contract,
// including ignored extra terminal padding and canonical output pad bits.
pub(crate) fn deserialize_data<'de,D:Deserializer<'de>>(deserializer:D)->std::result::Result<String,D::Error> {
    let text=String::deserialize(deserializer)?;
    canonical_data(&text).ok_or_else(||D::Error::custom("invalid native base64 Data"))
}
fn canonical_data(text:&str)->Option<String> {
    const ALPHABET:&[u8;64]=b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    fn digit(c:u8)->Option<u8>{match c{b'A'..=b'Z'=>Some(c-b'A'),b'a'..=b'z'=>Some(c-b'a'+26),b'0'..=b'9'=>Some(c-b'0'+52),b'+'=>Some(62),b'/'=>Some(63),_=>None}}
    let input=text.as_bytes();
    if input.is_empty(){return Some(String::new())}
    let mut bytes=Vec::new();
    if let Some(last)=input.iter().rposition(|&c|c!=b'=') {
        let end=(last+4)/4*4;
        if end>input.len(){return None}
        for (i,chunk) in input[..end].chunks_exact(4).enumerate(){
            let a=digit(chunk[0])?;let b=digit(chunk[1])?;
            let final_chunk=(i+1)*4==end;
            let c=if final_chunk && chunk[2]==b'=' {None}else{Some(digit(chunk[2])?)};
            let d=if final_chunk && chunk[3]==b'=' {None}else{Some(digit(chunk[3])?)};
            bytes.push((a<<2)|(b>>4));
            if let Some(c)=c{bytes.push((b<<4)|(c>>2))}
            if let Some(d)=d{bytes.push((c.unwrap_or(0)<<6)|d)}
        }
    }else if input.len()>=4{bytes.push(0)}else{return None}
    let mut output=String::with_capacity(bytes.len().div_ceil(3)*4);
    for chunk in bytes.chunks(3){
        let a=chunk[0];let b=chunk.get(1).copied().unwrap_or(0);let c=chunk.get(2).copied().unwrap_or(0);
        output.push(ALPHABET[(a>>2)as usize]as char);output.push(ALPHABET[(((a&3)<<4)|(b>>4))as usize]as char);
        output.push(if chunk.len()>1{ALPHABET[(((b&15)<<2)|(c>>6))as usize]as char}else{'='});
        output.push(if chunk.len()>2{ALPHABET[(c&63)as usize]as char}else{'='});
    }
    Some(output)
}
