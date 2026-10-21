//! One member of a requirement group, and the only place that reads one.
//!
//! A member is a condition's id ("home"), or that id after
//! [`NEGATION_PREFIX`] ("!home"): the task wants the condition **not** to
//! hold. Groups keep their meaning either way — any member of a group will
//! do, and every group must be met — so `[["!home"]]` is "only away from
//! Home" and `[["campus", "!quiet"]]` "on campus, or anywhere not quiet". A
//! group naming a condition both ways is always met, and is left alone.
//!
//! A client that predates negation reads "!home" as a condition it does not
//! know, which no context holds: the task waits, but nothing is lost.

use std::collections::HashSet;

/// What marks a member as negated.
pub const NEGATION_PREFIX: char = '!';

/// A requirement group member, read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Requirement<'a> {
    pub condition_id: &'a str,
    pub negated: bool,
}

impl<'a> Requirement<'a> {
    pub fn parse(member: &'a str) -> Self {
        match member.strip_prefix(NEGATION_PREFIX) {
            Some(id) => Requirement {
                condition_id: id,
                negated: true,
            },
            None => Requirement {
                condition_id: member,
                negated: false,
            },
        }
    }

    /// Whether it is met when `held` are the conditions that hold.
    pub fn is_met(&self, held: &HashSet<&str>) -> bool {
        held.contains(self.condition_id) != self.negated
    }

    /// The member as stored.
    pub fn member(&self) -> String {
        member(self.condition_id, self.negated)
    }
}

/// The member requiring `condition_id`, or its absence when `negated`.
pub fn member(condition_id: &str, negated: bool) -> String {
    if negated {
        format!("{NEGATION_PREFIX}{condition_id}")
    } else {
        condition_id.to_string()
    }
}

/// The condition a member names, negated or not.
pub fn condition_id_of(member: &str) -> &str {
    Requirement::parse(member).condition_id
}

/// Whether any member of `group` is met when `held` hold.
pub fn group_is_met(group: &[String], held: &HashSet<&str>) -> bool {
    group
        .iter()
        .any(|member| Requirement::parse(member).is_met(held))
}

/// The condition a requirement group member names, without its negation.
#[uniffi::export]
pub fn requirement_condition_id(member: String) -> String {
    condition_id_of(&member).to_string()
}

/// Whether a requirement group member asks for its condition not to hold.
#[uniffi::export]
pub fn requirement_is_negated(member: String) -> bool {
    Requirement::parse(&member).negated
}

/// The member requiring `condition_id`, or, `negated`, requiring it not to
/// hold.
#[uniffi::export]
pub fn requirement_member(condition_id: String, negated: bool) -> String {
    member(&condition_id, negated)
}

/// Whether a requirement group is met when `held_ids` hold: any one member
/// will do, a negated one by its condition not holding.
#[uniffi::export]
pub fn requirement_group_is_met(group: Vec<String>, held_ids: Vec<String>) -> bool {
    let held: HashSet<&str> = held_ids.iter().map(String::as_str).collect();
    group_is_met(&group, &held)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn groups(members: &[&str]) -> Vec<String> {
        members.iter().map(|m| m.to_string()).collect()
    }

    #[test]
    fn a_member_reads_as_its_condition_and_whether_it_is_negated() {
        assert_eq!(
            Requirement::parse("home"),
            Requirement {
                condition_id: "home",
                negated: false
            }
        );
        assert_eq!(
            Requirement::parse("!home"),
            Requirement {
                condition_id: "home",
                negated: true
            }
        );
        assert_eq!(requirement_member("home".into(), true), "!home");
        assert_eq!(requirement_member("home".into(), false), "home");
        assert_eq!(requirement_condition_id("!home".into()), "home");
        assert!(requirement_is_negated("!home".into()));
        assert!(!requirement_is_negated("home".into()));
    }

    #[test]
    fn a_negated_member_is_met_while_its_condition_does_not_hold() {
        let at_home: HashSet<&str> = ["home"].into();
        let nowhere = HashSet::new();
        assert!(!group_is_met(&groups(&["!home"]), &at_home));
        assert!(group_is_met(&groups(&["!home"]), &nowhere));
        // Any one member of a group will do.
        assert!(group_is_met(&groups(&["campus", "!quiet"]), &nowhere));
        assert!(!group_is_met(
            &groups(&["campus", "!quiet"]),
            &["quiet"].into()
        ));
        assert!(group_is_met(
            &groups(&["campus", "!quiet"]),
            &["campus", "quiet"].into()
        ));
        // A condition asked for both ways is always met.
        assert!(group_is_met(&groups(&["home", "!home"]), &at_home));
        assert!(group_is_met(&groups(&["home", "!home"]), &nowhere));
    }
}
