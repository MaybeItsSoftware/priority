//! How often a task comes round, and when it next does.
//!
//! The vocabulary is the one stored in `task_metadata.recurrenceRule`: plain
//! phrases a person would type ("daily", "weekdays", "every 3 days", "every
//! monday"), not an RFC 5545 subset. Swift's `PeriodicSchedule` and its
//! Kotlin namesake parse and step through this, by way of `recurrence.rs`.
//!
//! Stepping happens on the wall clock in the user's time zone, as
//! Foundation's `Calendar` and Java's `ZonedDateTime` do: a task due at 9:00
//! stays at 9:00 across a daylight-saving change.

use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDateTime, TimeZone, Utc, Weekday};
use chrono_tz::Tz;

/// A parsed recurrence rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cadence {
    Days(u32),
    Weeks(u32),
    /// Monday to Friday, skipping the weekend.
    Weekdays,
    Weekday(Weekday),
}

impl Cadence {
    /// Parses a stored rule; `None` for one this app did not write.
    pub fn parse(raw: &str) -> Option<Self> {
        let text = raw.trim().to_lowercase();
        match text.as_str() {
            "" => return None,
            "daily" | "every day" => return Some(Cadence::Days(1)),
            "weekly" | "every week" => return Some(Cadence::Weeks(1)),
            "weekdays" | "every weekday" => return Some(Cadence::Weekdays),
            _ => {}
        }
        let every_n = regex_lite::Regex::new(r"^every\s+(\d+)\s+(day|days|week|weeks|wk|wks)$")
            .expect("a fixed pattern compiles");
        if let Some(captures) = every_n.captures(&text) {
            let count: u32 = captures[1].parse().ok().filter(|count| *count > 0)?;
            let unit = &captures[2];
            return Some(if unit.starts_with("week") || unit.starts_with("wk") {
                Cadence::Weeks(count)
            } else {
                Cadence::Days(count)
            });
        }
        let name = text.strip_prefix("every ").unwrap_or(&text);
        weekday(name).map(Cadence::Weekday)
    }

    /// The first occurrence strictly after `reference`, and strictly after
    /// `not_before` when given.
    ///
    /// `not_before` is what makes a schedule survive being ignored: finishing
    /// a daily chore five days late steps the cadence until it lands in the
    /// future, keeping its rhythm rather than restarting it. Gives up after
    /// 400 steps, as the clients did.
    pub fn next_occurrence(
        &self,
        reference: DateTime<Utc>,
        not_before: Option<DateTime<Utc>>,
        zone: Tz,
    ) -> Option<DateTime<Utc>> {
        let threshold = not_before.map_or(reference, |floor| floor.max(reference));
        let mut candidate = reference.with_timezone(&zone).naive_local();
        for _ in 0..400 {
            candidate = self.step(candidate)?;
            let instant = resolve(zone, candidate);
            if instant > threshold {
                return Some(instant);
            }
        }
        None
    }

    /// One step on; `None` past the end of the calendar, where Foundation's
    /// `date(byAdding:)` gives up too, rather than overflowing.
    fn step(&self, from: NaiveDateTime) -> Option<NaiveDateTime> {
        let day = Duration::days(1);
        match *self {
            Cadence::Days(count) => from.checked_add_signed(Duration::days(i64::from(count))),
            Cadence::Weeks(count) => from.checked_add_signed(Duration::weeks(i64::from(count))),
            Cadence::Weekdays => {
                let mut next = from.checked_add_signed(day)?;
                while matches!(next.weekday(), Weekday::Sat | Weekday::Sun) {
                    next = next.checked_add_signed(day)?;
                }
                Some(next)
            }
            Cadence::Weekday(target) => {
                let mut next = from.checked_add_signed(day)?;
                for _ in 0..7 {
                    if next.weekday() == target {
                        break;
                    }
                    next = next.checked_add_signed(day)?;
                }
                Some(next)
            }
        }
    }
}

/// A wall-clock time in `zone` as an instant. A time the clocks skip over is
/// moved later by the length of the gap, and a time they repeat takes its
/// earlier occurrence, as Foundation and `ZonedDateTime` both resolve them.
pub(crate) fn resolve(zone: Tz, local: NaiveDateTime) -> DateTime<Utc> {
    match zone.from_local_datetime(&local) {
        LocalResult::Single(time) => time.with_timezone(&Utc),
        LocalResult::Ambiguous(earlier, _) => earlier.with_timezone(&Utc),
        LocalResult::None => {
            // Read the skipped time with the offset in force just before the
            // gap, which moves it later by the gap's length: 1:30 on a night
            // that jumps from 1:00 to 2:00 becomes 2:30.
            let before = zone
                .offset_from_local_datetime(&(local - Duration::hours(6)))
                .earliest()
                .map_or(0, |offset| chrono::Offset::fix(&offset).local_minus_utc());
            Utc.from_utc_datetime(&(local - Duration::seconds(i64::from(before))))
        }
    }
}

fn weekday(name: &str) -> Option<Weekday> {
    Some(match name {
        "sunday" | "sun" => Weekday::Sun,
        "monday" | "mon" => Weekday::Mon,
        "tuesday" | "tue" | "tues" => Weekday::Tue,
        "wednesday" | "wed" => Weekday::Wed,
        "thursday" | "thu" | "thur" | "thurs" => Weekday::Thu,
        "friday" | "fri" => Weekday::Fri,
        "saturday" | "sat" => Weekday::Sat,
        _ => return None,
    })
}

/// A zone by its IANA name, falling back to UTC for a name this build does
/// not know rather than refusing the write.
///
/// Also reads the fixed offsets Foundation names `GMT+0100` (a
/// `TimeZone(secondsFromGMT:)`, which tests use), as the `Etc/GMT` zone of
/// the same whole-hour offset.
pub fn zone(name: &str) -> Tz {
    if let Ok(zone) = name.parse() {
        return zone;
    }
    let fixed = name.strip_prefix("GMT").and_then(|rest| {
        let (sign, digits) = rest.split_at(rest.find(|c: char| c.is_ascii_digit())?);
        let hours: i32 = digits.get(..2)?.parse().ok()?;
        let minutes: i32 = digits
            .get(2..)
            .filter(|m| !m.is_empty())
            .map_or(Some(0), |m| m.parse().ok())?;
        if minutes != 0 {
            return None;
        }
        // Etc/GMT names count the other way: GMT+0100 is Etc/GMT-1.
        let inverted = match sign {
            "+" => -hours,
            "-" => hours,
            _ => return None,
        };
        if inverted == 0 {
            "Etc/GMT".parse().ok()
        } else {
            format!("Etc/GMT{inverted:+}").parse().ok()
        }
    });
    fixed.unwrap_or(Tz::UTC)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn rules_parse_as_they_are_typed() {
        assert_eq!(Cadence::parse(" Daily "), Some(Cadence::Days(1)));
        assert_eq!(Cadence::parse("every week"), Some(Cadence::Weeks(1)));
        assert_eq!(Cadence::parse("every weekday"), Some(Cadence::Weekdays));
        assert_eq!(Cadence::parse("every 3 days"), Some(Cadence::Days(3)));
        assert_eq!(Cadence::parse("every 2 wks"), Some(Cadence::Weeks(2)));
        assert_eq!(
            Cadence::parse("every thurs"),
            Some(Cadence::Weekday(Weekday::Thu))
        );
        assert_eq!(Cadence::parse("mon"), Some(Cadence::Weekday(Weekday::Mon)));
        for invalid in ["", "every 0 days", "fortnightly", "every -2 days"] {
            assert_eq!(Cadence::parse(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn a_late_finish_keeps_the_rhythm_and_lands_in_the_future() {
        let due = at("2026-03-02T09:00:00Z");
        let finished = at("2026-03-08T12:00:00Z");
        let next = Cadence::Days(3)
            .next_occurrence(due, Some(finished), Tz::UTC)
            .unwrap();
        assert_eq!(next, at("2026-03-11T09:00:00Z"));
    }

    #[test]
    fn the_time_of_day_survives_a_clock_change() {
        // London springs forward on 29 March 2026: 9:00 GMT, then 9:00 BST.
        let next = Cadence::Days(1)
            .next_occurrence(at("2026-03-28T09:00:00Z"), None, Tz::Europe__London)
            .unwrap();
        assert_eq!(next, at("2026-03-29T08:00:00Z"));
        // 1:30 does not exist that night; it moves an hour later, to 2:30 BST.
        let skipped = Cadence::Days(1)
            .next_occurrence(at("2026-03-28T01:30:00Z"), None, Tz::Europe__London)
            .unwrap();
        assert_eq!(skipped, at("2026-03-29T01:30:00Z"));
    }

    #[test]
    fn weekdays_and_named_days_step_by_the_local_calendar() {
        // Friday 6 March 2026, 23:30 in London.
        let friday = at("2026-03-06T23:30:00Z");
        assert_eq!(
            Cadence::Weekdays.next_occurrence(friday, None, Tz::Europe__London),
            Some(at("2026-03-09T23:30:00Z"))
        );
        assert_eq!(
            Cadence::Weekday(Weekday::Wed).next_occurrence(friday, None, Tz::Europe__London),
            Some(at("2026-03-11T23:30:00Z"))
        );
        // 23:30 UTC on Friday is already Saturday in Tokyo, so the next
        // weekday there is Monday.
        assert_eq!(
            Cadence::Weekdays.next_occurrence(friday, None, Tz::Asia__Tokyo),
            Some(at("2026-03-08T23:30:00Z"))
        );
    }

    #[test]
    fn zone_names_and_foundations_fixed_offsets_are_read() {
        assert_eq!(zone("Nowhere/Special"), Tz::UTC);
        assert_eq!(zone("Europe/London"), Tz::Europe__London);
        assert_eq!(zone("GMT"), Tz::GMT);
        assert_eq!(zone("GMT+0100"), Tz::Etc__GMTMinus1);
        assert_eq!(zone("GMT-0500"), Tz::Etc__GMTPlus5);
        assert_eq!(zone("GMT+0530"), Tz::UTC);
    }
}
