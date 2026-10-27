//! JSON exactly as the macOS helper prints it: sorted keys, two-space
//! indentation, `"key" : value`, whole numbers without a fraction and, unless
//! asked otherwise, `/` escaped as `\/` (Swift's `JSONEncoder`).

use serde::Serialize;
use serde_json::Value;

/// Pretty JSON with Swift's separators. `escape_slashes` mirrors encoders
/// without `.withoutEscapingSlashes`.
pub fn pretty<T: Serialize>(value: &T, escape_slashes: bool) -> String {
    let value = normalize(serde_json::to_value(value).unwrap_or(Value::Null));
    let mut out = Vec::new();
    let mut serializer =
        serde_json::Serializer::with_formatter(&mut out, SwiftFormatter::default());
    if value.serialize(&mut serializer).is_err() {
        return "null".into();
    }
    let text = String::from_utf8(out).unwrap_or_default();
    if escape_slashes {
        text.replace('/', "\\/")
    } else {
        text
    }
}

/// Compact JSON with sorted keys and unescaped slashes (MCP wire format).
pub fn compact(value: &Value) -> String {
    serde_json::to_string(&normalize(value.clone())).unwrap_or_else(|_| "null".into())
}

/// Sorts object keys and turns whole floating-point numbers into integers.
pub fn normalize(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: std::collections::BTreeMap<String, Value> =
                map.into_iter().map(|(k, v)| (k, normalize(v))).collect();
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(normalize).collect()),
        Value::Number(number) => match number.as_f64() {
            Some(f) if number.is_f64() && f.fract() == 0.0 && f.abs() < 1e15 => {
                Value::from(f as i64)
            }
            _ => Value::Number(number),
        },
        other => other,
    }
}

#[derive(Default)]
struct SwiftFormatter {
    indent: usize,
    has_value: bool,
}

impl SwiftFormatter {
    fn newline<W: ?Sized + std::io::Write>(&self, writer: &mut W) -> std::io::Result<()> {
        writer.write_all(b"\n")?;
        for _ in 0..self.indent {
            writer.write_all(b"  ")?;
        }
        Ok(())
    }
}

impl serde_json::ser::Formatter for SwiftFormatter {
    fn begin_array<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"[")
    }

    fn end_array<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.indent -= 1;
        if self.has_value {
            self.newline(writer)?;
        } else {
            writer.write_all(b"\n")?;
            self.newline(writer)?;
        }
        writer.write_all(b"]")
    }

    fn begin_array_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> std::io::Result<()> {
        if !first {
            writer.write_all(b",")?;
        }
        self.newline(writer)
    }

    fn end_array_value<W: ?Sized + std::io::Write>(
        &mut self,
        _writer: &mut W,
    ) -> std::io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn begin_object<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"{")
    }

    fn end_object<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.indent -= 1;
        if self.has_value {
            self.newline(writer)?;
        } else {
            writer.write_all(b"\n")?;
            self.newline(writer)?;
        }
        writer.write_all(b"}")
    }

    fn begin_object_key<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> std::io::Result<()> {
        if !first {
            writer.write_all(b",")?;
        }
        self.newline(writer)
    }

    fn begin_object_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
    ) -> std::io::Result<()> {
        writer.write_all(b" : ")
    }

    fn end_object_value<W: ?Sized + std::io::Write>(
        &mut self,
        _writer: &mut W,
    ) -> std::io::Result<()> {
        self.has_value = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_swift_pretty_printing() {
        let value = serde_json::json!({"b": 1.0, "a": "x/y", "c": [1, {"d": 2.5}], "e": []});
        assert_eq!(
            pretty(&value, true),
            "{\n  \"a\" : \"x\\/y\",\n  \"b\" : 1,\n  \"c\" : [\n    1,\n    {\n      \"d\" : 2.5\n    }\n  ],\n  \"e\" : [\n\n  ]\n}"
        );
        assert_eq!(
            compact(&serde_json::json!({"b": 1, "a": "x/y"})),
            "{\"a\":\"x/y\",\"b\":1}"
        );
    }
}
