use crate::{Client, Error, Result, Value};
use serde::{Deserialize, Serialize};
use serde_json::json;

const START_REQUEST: &str = "ComputerUseIPCStartAudioRecordingRequest";
const STOP_REQUEST: &str = "ComputerUseIPCStopAudioRecordingRequest";

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioRecordingOptions {
    /// The service defaults to 60 seconds when the field is omitted.
    /// Explicit durations must be between 100 and 300,000 milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_duration_milliseconds: Option<u64>,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct AudioRecording {
    /// File URL of the WAV on the service's machine. The service schedules
    /// deletion 30 seconds after Stop produces this URL; read or copy it promptly.
    #[cfg_attr(target_os = "macos", serde(deserialize_with = "crate::foundation::deserialize_url"))]
    pub url: String,
}
}

impl Client {
    pub fn start_audio_recording(&mut self, max_duration_milliseconds: u64) -> Result<()> {
        if max_duration_milliseconds > i64::MAX as u64 {
            return Err(Error::InvalidInput("audio duration overflow".into()));
        }
        self.request_empty_response(
            START_REQUEST,
            AudioRecordingOptions {
                max_duration_milliseconds: Some(max_duration_milliseconds),
            },
        )
    }

    /// Starts recording with an optional automatic stop duration.
    pub fn start_audio_recording_typed(&mut self, options: AudioRecordingOptions) -> Result<()> {
        if let Some(milliseconds) = options.max_duration_milliseconds {
            if !(100..=300_000).contains(&milliseconds) {
                return Err(Error::InvalidInput(
                    "audio recording duration must be between 100 and 300000 milliseconds".into(),
                ));
            }
        }
        self.request_empty_response(START_REQUEST, options)
    }

    pub fn stop_audio_recording(&mut self) -> Result<Value> {
        self.request(STOP_REQUEST, json!({}))
    }

    /// Stops the owner's recording or retrieves it after an automatic stop.
    /// The returned file is temporary and is scheduled for deletion after 30 seconds.
    /// An automatically stopped recording must be retrieved within 30 seconds;
    /// otherwise the service removes the unclaimed file and its ownership metadata.
    /// Across clients sharing a recording, complete all pending Starts and Stops before another Start:
    /// the native recorder allows reentrant claims and a late successful Stop
    /// clears current recording metadata, as does a late failure from an older Start.
    pub fn stop_audio_recording_typed(&mut self) -> Result<AudioRecording> {
        self.request(STOP_REQUEST, json!({}))
    }
}
