//! JSON the way the theme format has always read and written it.
//!
//! The format was defined by Swift's `JSONDecoder` and `JSONEncoder`, so this
//! reads and writes their dialect rather than strict JSON: a trailing comma is
//! accepted, a key stated twice keeps its first value, and output is
//! pretty-printed with sorted keys, `"key" : value`, and integral numbers
//! without a fraction. The shared files in `shared/themes/` are these bytes.

/// A parsed value. Objects keep every entry, in document order.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    /// Written as Swift writes an `Int`: every digit, never an exponent. The
    /// reader never makes one; it is for writers whose fields are integers.
    Integer(i64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    /// The first value under `key`, as a decoder looking a field up finds it.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn object<I, K>(entries: I) -> Json
    where
        I: IntoIterator<Item = (K, Option<Json>)>,
        K: Into<String>,
    {
        Json::Object(
            entries
                .into_iter()
                .filter_map(|(key, value)| value.map(|v| (key.into(), v)))
                .collect(),
        )
    }
}

// MARK: - Reading

/// Parses `bytes`: UTF-8 with or without a byte-order mark, or UTF-16 with
/// one. `None` is "not valid JSON".
pub fn parse(bytes: &[u8]) -> Option<Json> {
    let text = decode_text(bytes)?;
    let mut parser = Parser {
        chars: text.chars().collect(),
        at: 0,
    };
    parser.skip_whitespace();
    let value = parser.value(0)?;
    parser.skip_whitespace();
    (parser.at == parser.chars.len()).then_some(value)
}

fn decode_text(bytes: &[u8]) -> Option<String> {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(rest.to_vec()).ok();
    }
    let utf16 = |rest: &[u8], little: bool| -> Option<String> {
        if !rest.len().is_multiple_of(2) {
            return None;
        }
        let units: Vec<u16> = rest
            .chunks(2)
            .map(|pair| {
                if little {
                    u16::from_le_bytes([pair[0], pair[1]])
                } else {
                    u16::from_be_bytes([pair[0], pair[1]])
                }
            })
            .collect();
        String::from_utf16(&units).ok()
    };
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(rest, true);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(rest, false);
    }
    String::from_utf8(bytes.to_vec()).ok()
}

struct Parser {
    chars: Vec<char>,
    at: usize,
}

const MAX_DEPTH: usize = 512;

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\n' | '\r')) {
            self.at += 1;
        }
    }

    fn expect(&mut self, literal: &str) -> Option<()> {
        for expected in literal.chars() {
            if self.peek()? != expected {
                return None;
            }
            self.at += 1;
        }
        Some(())
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > MAX_DEPTH {
            return None;
        }
        match self.peek()? {
            '{' => self.object(depth),
            '[' => self.array(depth),
            '"' => self.string().map(Json::String),
            't' => self.expect("true").map(|_| Json::Bool(true)),
            'f' => self.expect("false").map(|_| Json::Bool(false)),
            'n' => self.expect("null").map(|_| Json::Null),
            '-' | '0'..='9' => self.number().map(Json::Number),
            _ => None,
        }
    }

    fn object(&mut self, depth: usize) -> Option<Json> {
        self.at += 1;
        let mut entries = Vec::new();
        loop {
            self.skip_whitespace();
            if self.peek()? == '}' {
                self.at += 1;
                return Some(Json::Object(entries));
            }
            if self.peek()? != '"' {
                return None;
            }
            let key = self.string()?;
            self.skip_whitespace();
            self.expect(":")?;
            self.skip_whitespace();
            let value = self.value(depth + 1)?;
            entries.push((key, value));
            self.skip_whitespace();
            match self.peek()? {
                ',' => self.at += 1,
                '}' => {
                    self.at += 1;
                    return Some(Json::Object(entries));
                }
                _ => return None,
            }
        }
    }

    fn array(&mut self, depth: usize) -> Option<Json> {
        self.at += 1;
        let mut items = Vec::new();
        loop {
            self.skip_whitespace();
            if self.peek()? == ']' {
                self.at += 1;
                return Some(Json::Array(items));
            }
            items.push(self.value(depth + 1)?);
            self.skip_whitespace();
            match self.peek()? {
                ',' => self.at += 1,
                ']' => {
                    self.at += 1;
                    return Some(Json::Array(items));
                }
                _ => return None,
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let mut value = 0u32;
        for _ in 0..4 {
            let digit = self.peek()?.to_digit(16)?;
            value = value * 16 + digit;
            self.at += 1;
        }
        Some(value)
    }

    fn string(&mut self) -> Option<String> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let c = self.peek()?;
            self.at += 1;
            match c {
                '"' => return Some(out),
                '\\' => {
                    let escape = self.peek()?;
                    self.at += 1;
                    match escape {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{8}'),
                        'f' => out.push('\u{c}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let unit = self.hex4()?;
                            if (0xD800..0xDC00).contains(&unit) {
                                // A high surrogate has to be followed by its low half.
                                self.expect("\\u")?;
                                let low = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&low) {
                                    return None;
                                }
                                let scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                                out.push(char::from_u32(scalar)?);
                            } else {
                                out.push(char::from_u32(unit)?);
                            }
                        }
                        _ => return None,
                    }
                }
                c if (c as u32) < 0x20 => return None,
                c => out.push(c),
            }
        }
    }

    fn number(&mut self) -> Option<f64> {
        let start = self.at;
        if self.peek() == Some('-') {
            self.at += 1;
        }
        let digits = |p: &mut Parser| {
            let from = p.at;
            while matches!(p.peek(), Some('0'..='9')) {
                p.at += 1;
            }
            p.at - from
        };
        let first = self.peek()?;
        let integer = digits(self);
        if integer == 0 || (first == '0' && integer > 1) {
            return None;
        }
        if self.peek() == Some('.') {
            self.at += 1;
            if digits(self) == 0 {
                return None;
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            self.at += 1;
            if matches!(self.peek(), Some('+' | '-')) {
                self.at += 1;
            }
            if digits(self) == 0 {
                return None;
            }
        }
        let text: String = self.chars[start..self.at].iter().collect();
        let value: f64 = text.parse().ok()?;
        // Out of range either way is not a number Swift will read.
        let mantissa_is_zero = text
            .split(['e', 'E'])
            .next()
            .unwrap_or("")
            .chars()
            .all(|c| matches!(c, '0' | '.' | '-'));
        if !value.is_finite() || (value == 0.0 && !mantissa_is_zero) {
            return None;
        }
        Some(value)
    }
}

// MARK: - Writing

/// Pretty-printed, keys sorted, slashes left alone: `JSONEncoder` with
/// `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`. No trailing
/// newline. `None` when a number is not finite, which JSON cannot hold.
pub fn pretty(value: &Json) -> Option<String> {
    let mut out = String::new();
    write(value, &mut out, 0, false)?;
    Some(out)
}

/// `pretty` without `.withoutEscapingSlashes`: every `/` written `\/`, as
/// `JSONEncoder` does by default. The workspace export is written this way.
pub fn pretty_escaping_slashes(value: &Json) -> Option<String> {
    let mut out = String::new();
    write(value, &mut out, 0, true)?;
    Some(out)
}

fn write(value: &Json, out: &mut String, depth: usize, slashes: bool) -> Option<()> {
    let indent = "  ".repeat(depth + 1);
    let closing = "  ".repeat(depth);
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Number(n) => {
            if !n.is_finite() {
                return None;
            }
            out.push_str(&json_number(*n));
        }
        Json::Integer(n) => out.push_str(&n.to_string()),
        Json::String(s) => write_string(s, out, slashes),
        Json::Array(items) => {
            out.push_str("[\n");
            if items.is_empty() {
                out.push('\n');
            }
            for (index, item) in items.iter().enumerate() {
                out.push_str(&indent);
                write(item, out, depth + 1, slashes)?;
                if index + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&closing);
            out.push(']');
        }
        Json::Object(entries) => {
            let mut sorted: Vec<&(String, Json)> = entries.iter().collect();
            sorted.sort_by(|a, b| a.0.cmp(&b.0));
            out.push_str("{\n");
            if sorted.is_empty() {
                out.push('\n');
            }
            for (index, (key, item)) in sorted.iter().enumerate() {
                out.push_str(&indent);
                write_string(key, out, slashes);
                out.push_str(" : ");
                write(item, out, depth + 1, slashes)?;
                if index + 1 < sorted.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&closing);
            out.push('}');
        }
    }
    Some(())
}

fn write_string(s: &str, out: &mut String, slashes: bool) {
    out.push('"');
    for c in s.chars() {
        match c {
            '/' if slashes => out.push_str("\\/"),
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A number as `JSONEncoder` writes it: Swift's description without a
/// trailing `.0`, so `13`, `0.15`, `-0`, `1e+16`.
pub fn json_number(value: f64) -> String {
    let text = swift_description(value);
    text.strip_suffix(".0").map(str::to_string).unwrap_or(text)
}

/// `String(value)` in Swift: the shortest digits that read back the same,
/// in positional notation from 1e-4 up to 1e16 and exponential outside it.
pub fn swift_description(value: f64) -> String {
    if value.is_nan() {
        return "nan".to_string();
    }
    if value.is_infinite() {
        return if value < 0.0 { "-inf" } else { "inf" }.to_string();
    }
    let sign = if value.is_sign_negative() { "-" } else { "" };
    let magnitude = value.abs();
    if magnitude == 0.0 {
        return format!("{sign}0.0");
    }
    // `{:e}` is the shortest round-tripping digits: `1.5e300`, `1e-5`.
    let scientific = format!("{magnitude:e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    if !(1e-4..1e16).contains(&magnitude) {
        let sign_e = if exponent < 0 { "-" } else { "+" };
        return format!("{sign}{mantissa}e{sign_e}{:02}", exponent.abs());
    }
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let point = exponent + 1; // digits before the decimal point
    let body = if point <= 0 {
        format!("0.{}{}", "0".repeat((-point) as usize), digits)
    } else if point as usize >= digits.len() {
        format!("{}{}.0", digits, "0".repeat(point as usize - digits.len()))
    } else {
        let (whole, fraction) = digits.split_at(point as usize);
        format!("{whole}.{fraction}")
    };
    format!("{sign}{body}")
}

/// `-2` rather than `-2.0` in a message, the way the file was written; any
/// other value as Swift describes it.
pub fn message_number(value: f64) -> String {
    if value.is_finite() && value == value.round() && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        swift_description(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_are_written_the_way_swift_writes_them() {
        let cases = [
            (13.0, "13"),
            (0.15, "0.15"),
            (1e-5, "1e-05"),
            (0.0001, "0.0001"),
            (1e15, "1000000000000000"),
            (1e16, "1e+16"),
            (999999999999999.0, "999999999999999"),
            (1234567890123456.0, "1234567890123456"),
            (1.5e300, "1.5e+300"),
            (-0.0, "-0"),
            (0.1 + 0.2, "0.30000000000000004"),
            (5e-324, "5e-324"),
            (123456.789, "123456.789"),
        ];
        for (value, expected) in cases {
            assert_eq!(json_number(value), expected, "{value}");
        }
        assert_eq!(swift_description(9007199254740992.0), "9007199254740992.0");
        assert_eq!(swift_description(0.000123), "0.000123");
        assert_eq!(swift_description(-2.5e20), "-2.5e+20");
        assert_eq!(message_number(-1.0), "-1");
        assert_eq!(message_number(-0.5), "-0.5");
        assert_eq!(message_number(1e15), "1000000000000000.0");
    }

    #[test]
    fn strings_escape_as_swift_does() {
        let mut out = String::new();
        write_string(
            "a/b\"\\\n\t\u{1}\u{1f}\u{7f}é\u{2028}😀\r\u{8}\u{c}",
            &mut out,
            false,
        );
        assert_eq!(
            out,
            "\"a/b\\\"\\\\\\n\\t\\u0001\\u001f\u{7f}é\u{2028}😀\\r\\b\\f\""
        );
    }

    #[test]
    fn empty_containers_keep_their_blank_line() {
        let value = Json::object([
            ("a", Some(Json::Array(vec![]))),
            ("e", Some(Json::Object(vec![]))),
        ]);
        assert_eq!(
            pretty(&value).unwrap(),
            "{\n  \"a\" : [\n\n  ],\n  \"e\" : {\n\n  }\n}"
        );
    }

    #[test]
    fn the_reader_takes_swifts_dialect() {
        assert!(parse(b"{\"a\": 1,}").is_some());
        assert!(parse(b"{\"b\": [\"x\",]}").is_some());
        assert_eq!(
            parse(b"{\"a\": 1, \"a\": 2}").unwrap().get("a"),
            Some(&Json::Number(1.0))
        );
        assert!(parse("\u{FEFF}{\"a\":1}".as_bytes()).is_some());
        assert!(parse(&[0xff, 0xfe, 0x7b, 0x00, 0x7d, 0x00]).is_some());
        for bad in [
            "{,}",
            "{\"a\": 1,,}",
            "{\"a\": 1.}",
            "{\"a\": .5}",
            "{\"a\": -}",
            "{\"a\": 01}",
            "{\"a\": NaN}",
            "{\"a\": 1e400}",
            "{\"a\": 1e-400}",
            "{\"a\": 1} x",
            "{'a': 1}",
            "{\"s\": \"\\ud800\"}",
            "{\"s\": \"\\x\"}",
            "{\"a\":\u{a0}1}",
            "  ",
            "",
            "{\"s\": \"a\tb\"}",
        ] {
            assert_eq!(parse(bad.as_bytes()), None, "{bad}");
        }
        assert_eq!(
            parse(b"{\"a\": 1E+2}").unwrap().get("a"),
            Some(&Json::Number(100.0))
        );
        assert_eq!(
            parse(b"{\"a\": 0.1e1}").unwrap().get("a"),
            Some(&Json::Number(1.0))
        );
        assert!(parse(&[0x7b, 0x22, 0x73, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d]).is_none());
    }
}
