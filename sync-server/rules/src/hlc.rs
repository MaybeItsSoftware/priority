//! A hybrid logical clock: wall time where the devices agree, and a counter to
//! break ties where they do not, so every edit gets a stamp no other edit on
//! any device shares, and a device that has seen an edit always stamps its
//! next one later.
//!
//! Rendered as `"<ms:013>-<counter:04>-<deviceId>"`. Every numeric part is
//! fixed width, so string order is clock order; the server compares stamps as
//! strings and never parses them.

use std::fmt;

/// One stamp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hlc {
    pub milliseconds: i64,
    pub counter: u32,
    pub device_id: String,
}

impl Hlc {
    pub fn new(milliseconds: i64, counter: u32, device_id: impl Into<String>) -> Self {
        Self {
            milliseconds,
            counter,
            device_id: device_id.into(),
        }
    }

    /// A stamp read back from its text; absent when it is not one.
    pub fn parse(text: &str) -> Option<Self> {
        let mut parts = text.splitn(3, '-');
        let milliseconds = parts.next()?.parse().ok()?;
        let counter = parts.next()?.parse().ok()?;
        let device_id = parts.next()?;
        Some(Self::new(milliseconds, counter, device_id))
    }

    /// The stamp for a local edit made at `wall_ms`.
    pub fn tick(&self, wall_ms: i64) -> Self {
        if wall_ms > self.milliseconds {
            Self::new(wall_ms, 0, self.device_id.clone())
        } else {
            Self::new(self.milliseconds, self.counter + 1, self.device_id.clone())
        }
    }

    /// This clock moved past one received from another device, so the next
    /// local edit sorts after everything this device has seen.
    pub fn receiving(&self, remote: &Hlc, wall_ms: i64) -> Self {
        let ms = self.milliseconds.max(remote.milliseconds).max(wall_ms);
        let counter = if ms == self.milliseconds && ms == remote.milliseconds {
            self.counter.max(remote.counter) + 1
        } else if ms == self.milliseconds {
            self.counter + 1
        } else if ms == remote.milliseconds {
            remote.counter + 1
        } else {
            0
        };
        Self::new(ms, counter, self.device_id.clone())
    }
}

impl fmt::Display for Hlc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:013}-{:04}-{}",
            self.milliseconds, self.counter, self.device_id
        )
    }
}

/// Whether `hlc` has the `"<ms:013>-<counter:04>-<deviceId>"` shape.
///
/// Every comparison is plain string order, which is only the clock's order
/// when the numeric parts are fixed width. A malformed stamp would not fail;
/// it would silently win or lose against everything, so the server refuses
/// it at the door instead.
pub fn is_valid(hlc: &str) -> bool {
    let bytes = hlc.as_bytes();
    bytes.len() > 19
        && bytes[..13].iter().all(u8::is_ascii_digit)
        && bytes[13] == b'-'
        && bytes[14..18].iter().all(u8::is_ascii_digit)
        && bytes[18] == b'-'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stamp_reads_back_as_itself_and_sorts_as_text() {
        let stamp = Hlc::new(1_700_000_000_000, 7, "MAC");
        assert_eq!(stamp.to_string(), "1700000000000-0007-MAC");
        assert_eq!(Hlc::parse(&stamp.to_string()), Some(stamp.clone()));
        assert!(is_valid(&stamp.to_string()));
        assert!(Hlc::new(5, 0, "A").to_string() < Hlc::new(40, 0, "A").to_string());
        // A device id may itself hold dashes.
        assert_eq!(
            Hlc::parse("0000000000001-0002-AB-CD").map(|h| h.device_id),
            Some("AB-CD".into())
        );
        assert_eq!(Hlc::parse("nonsense"), None);
        assert!(!is_valid("1-2-x"));
    }

    #[test]
    fn ticks_follow_the_wall_clock_or_count_when_it_stalls() {
        let clock = Hlc::new(100, 3, "A");
        assert_eq!(clock.tick(200), Hlc::new(200, 0, "A"));
        assert_eq!(clock.tick(100), Hlc::new(100, 4, "A"));
        assert_eq!(clock.tick(50), Hlc::new(100, 4, "A"));
    }

    #[test]
    fn receiving_moves_past_the_remote_stamp() {
        let local = Hlc::new(100, 3, "A");
        assert_eq!(
            local.receiving(&Hlc::new(100, 9, "B"), 50),
            Hlc::new(100, 10, "A")
        );
        assert_eq!(
            local.receiving(&Hlc::new(150, 2, "B"), 50),
            Hlc::new(150, 3, "A")
        );
        assert_eq!(
            local.receiving(&Hlc::new(90, 2, "B"), 50),
            Hlc::new(100, 4, "A")
        );
        assert_eq!(
            local.receiving(&Hlc::new(90, 2, "B"), 300),
            Hlc::new(300, 0, "A")
        );
    }
}
