//! Preserve the first occurrence of each object key, as native keyed decoding
//! does. Later values are still fully parsed, so malformed JSON never passes.

use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::fmt;

pub(crate) struct NativeValue(pub Value);

impl<'de> Deserialize<'de> for NativeValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct NativeVisitor;
        impl<'de> Visitor<'de> for NativeVisitor {
            type Value = NativeValue;
            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a JSON value")
            }
            fn visit_unit<E>(self) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::Null))
            }
            fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::Bool(value)))
            }
            fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::Number(value.into())))
            }
            fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::Number(value.into())))
            }
            fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E> {
                Ok(NativeValue(
                    Number::from_f64(value)
                        .map(Value::Number)
                        .unwrap_or(Value::Null),
                ))
            }
            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::String(value.to_owned())))
            }
            fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
                Ok(NativeValue(Value::String(value)))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut sequence: A,
            ) -> Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(NativeValue(value)) = sequence.next_element()? {
                    values.push(value);
                }
                Ok(NativeValue(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut object: A) -> Result<Self::Value, A::Error> {
                let mut values = Map::new();
                while let Some((key, NativeValue(value))) =
                    object.next_entry::<String, NativeValue>()?
                {
                    values.entry(key).or_insert(value);
                }
                let object = Value::Object(values);
                // With serde_json's arbitrary_precision feature, numeric
                // tokens use its Number deserializer's map representation.
                // Delegate recognition to Number itself, including when an
                // embedding application enables that dependency feature.
                if object.as_object().is_some_and(|fields| fields.len() == 1) {
                    if let Ok(number) = Number::deserialize(&object) {
                        return Ok(NativeValue(Value::Number(number)));
                    }
                }
                Ok(NativeValue(object))
            }
        }
        deserializer.deserialize_any(NativeVisitor)
    }
}
