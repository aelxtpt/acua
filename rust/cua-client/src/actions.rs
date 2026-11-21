use crate::{nonempty, Error, Result};
use serde::{Serialize, Serializer};
use serde_json::Value;

/// Coordinates use the captured image's coordinate space.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Point([f64; 2]);
impl Point {
    pub fn new(x: f64, y: f64) -> Result<Self> {
        if !x.is_finite() || !y.is_finite() {
            return Err(Error::InvalidInput("coordinates must be finite".into()));
        }
        Ok(Self([x, y]))
    }
}

#[derive(Debug, Clone, Serialize)]
pub enum Target {
    #[serde(rename = "coordinate")]
    Coordinate {
        #[serde(rename = "_0")]
        point: Point,
    },
    #[serde(rename = "elementID")]
    ElementId {
        #[serde(rename = "_0")]
        id: String,
    },
}
impl Target {
    pub fn coordinate(x: f64, y: f64) -> Result<Self> {
        Ok(Self::Coordinate {
            point: Point::new(x, y)?,
        })
    }
    pub fn element(id: impl ToString) -> Self {
        Self::ElementId { id: id.to_string() }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    /// A raw native UInt32 button number, including additional mouse buttons.
    Other(u32),
}
impl Serialize for MouseButton {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_u32(match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Middle => 2,
            Self::Other(button) => *button,
        })
    }
}
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}
#[derive(Debug, Clone, Copy, Serialize)]
pub enum PasteFormat {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "md")]
    Markdown,
    #[serde(rename = "html")]
    Html,
}
#[derive(Debug, Clone, Copy, Serialize)]
pub enum Selection {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "cursor_before")]
    CursorBefore,
    #[serde(rename = "cursor_after")]
    CursorAfter,
}

/// Mirrors Swift's externally tagged action union, including `_0` payloads.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Click {
        at: Target,
        #[serde(rename = "clickCount")]
        click_count: u64,
        #[serde(rename = "mouseButton")]
        mouse_button: MouseButton,
        #[serde(skip_serializing_if = "Option::is_none")]
        key: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        duration: Option<f64>,
    },
    Drag {
        from: Point,
        to: Point,
    },
    Type {
        #[serde(rename = "_0")]
        text: String,
    },
    PressKey {
        #[serde(rename = "_0")]
        key: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        duration: Option<f64>,
    },
    Paste {
        text: String,
        format: PasteFormat,
    },
    Scroll {
        at: Target,
        direction: Direction,
        pages: f64,
    },
    SetValue {
        #[serde(rename = "elementID")]
        element_id: String,
        /// Native setValue requires a JSON string. Other values are rejected
        /// locally by the action methods before allocating a request ID.
        value: Value,
    },
    SelectText {
        #[serde(rename = "elementID")]
        element_id: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        prefix: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        suffix: Option<String>,
        selection: Selection,
    },
    PerformSecondaryAction {
        /// Use the description shown in the native observation, e.g. "Show Menu".
        action: String,
        #[serde(rename = "elementID")]
        element_id: String,
    },
}
impl Action {
    pub fn click(at: Target) -> Self {
        Self::Click {
            at,
            click_count: 1,
            mouse_button: MouseButton::Left,
            key: None,
            duration: None,
        }
    }
    pub fn type_text(text: impl Into<String>) -> Self {
        Self::Type { text: text.into() }
    }
    pub fn press_key(key: impl Into<String>) -> Self {
        Self::PressKey {
            key: key.into(),
            duration: None,
        }
    }
    /// Sets the text value of the native accessibility element.
    /// Empty strings are valid and clear the field; content is not trimmed.
    pub fn set_value(element_id: impl ToString, value: impl Into<String>) -> Self {
        Self::SetValue {
            element_id: element_id.to_string(),
            value: Value::String(value.into()),
        }
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if let Self::SetValue { value, .. } = self {
            if !value.is_string() {
                return Err(Error::InvalidInput("setValue requires a string value".into()));
            }
        }
        if let Self::Click { click_count, .. } = self {
            if *click_count > i64::MAX as u64 {
                return Err(Error::InvalidInput(
                    "click count must fit a signed 64-bit integer".into(),
                ));
            }
        }
        match self {
            Self::Click { duration, .. } | Self::PressKey { duration, .. } => {
                if duration.is_some_and(|n| !n.is_finite()) {
                    return Err(Error::InvalidInput("duration must be finite".into()));
                }
            }
            Self::Scroll { pages, .. } if !pages.is_finite() || *pages <= 0.0 => {
                return Err(Error::InvalidInput(
                    "scroll pages must be finite and positive".into(),
                ));
            }
            _ => {}
        }
        if let Self::PressKey { key, .. } = self {
            nonempty(key, "key")?;
        }
        Ok(())
    }
}
