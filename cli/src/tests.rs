//! Unit tests for the parts of the CLI that are logic rather than plumbing.
//!
//! Deliberately not a re-run of `scripts/mcp_parity_check.py`: that check
//! compares this implementation against the other two from the outside, and is
//! the authority on whether they agree. These tests cover what it cannot —
//! the CLI's own argument handling, and the invariants that would let this
//! implementation drift *before* anyone runs a comparison.

use crate::checkvist::{CheckvistClient, CheckvistConfig, depth_first_tasks};
use crate::cli::{Cli, parse_weekdays, resolve};
use crate::config::{Config, Source, choose};
use crate::local::LocalState;
use crate::mcp::{tool_definitions, tool_result_text};
use crate::tools::{Tools, as_bool, as_optional_int, as_optional_weekdays, filter_tasks};
use chrono::{Local, TimeZone};
use clap::Parser;
use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

// -- helpers -----------------------------------------------------------------

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A private store directory per test. Tests run in threads within one process
/// and several of them write `dailies.json`, so sharing one would have them
/// take each other's lock and see each other's dailies.
fn scratch() -> LocalState {
    let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
    let directory =
        std::env::temp_dir().join(format!("priority-tests-{}-{unique}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("scratch directory");
    LocalState {
        prefs_path: directory.join("missing.plist"),
        store_directory: directory,
    }
}

fn tools_for(local: LocalState) -> Tools {
    Tools {
        client: CheckvistClient::new(CheckvistConfig {
            username: String::new(),
            remote_key: String::new(),
            default_list_id: "999".into(),
            base_url: "https://checkvist.invalid".into(),
        }),
        local,
    }
}

fn stored_dailies(local: &LocalState) -> Vec<Value> {
    let text = std::fs::read_to_string(local.dailies_path()).expect("dailies.json");
    serde_json::from_str::<Value>(&text).expect("valid JSON")["dailies"]
        .as_array()
        .expect("dailies array")
        .clone()
}

// -- day boundary ------------------------------------------------------------

#[test]
fn work_finished_after_midnight_belongs_to_the_previous_day() {
    let local = scratch();
    // 01:30 under the default 4am rollover is still the day that began
    // yesterday morning — the whole point of a logical day.
    let late = Local.with_ymd_and_hms(2026, 8, 15, 1, 30, 0).unwrap();
    assert_eq!(local.day_key(late), "2026-08-14");

    let morning = Local.with_ymd_and_hms(2026, 8, 15, 5, 0, 0).unwrap();
    assert_eq!(local.day_key(morning), "2026-08-15");
}

#[test]
fn logical_day_is_idempotent() {
    // These values are passed back in as day identifiers, so re-keying one must
    // not shift it another day earlier every time.
    let local = scratch();
    let moment = Local.with_ymd_and_hms(2026, 8, 15, 1, 30, 0).unwrap();
    let once = local.logical_day(moment);
    assert_eq!(local.logical_day(once), once);
    assert_eq!(local.day_key(once), local.day_key(moment));
}

#[test]
fn a_missing_preferences_file_still_gives_the_default_rollover() {
    assert_eq!(
        scratch().rollover_hour(),
        crate::local::DEFAULT_ROLLOVER_HOUR
    );
}

// -- aggregation -------------------------------------------------------------

fn write_log(local: &LocalState, events: &[Value]) {
    let lines: Vec<String> = events.iter().map(Value::to_string).collect();
    std::fs::write(local.daylog_path(), lines.join("\n") + "\n").expect("write day log");
}

#[test]
fn a_reopen_cancels_its_completion_even_on_a_later_day() {
    let local = scratch();
    write_log(
        &local,
        &[
            json!({"kind": "completed", "at": "2026-08-14T10:00:00Z", "taskId": 11, "title": "Survives"}),
            json!({"kind": "completed", "at": "2026-08-14T10:05:00Z", "taskId": 12, "title": "Undone"}),
            // The reopen lands the *next* day, and must still cancel yesterday's
            // completion rather than counting against today.
            json!({"kind": "reopened", "at": "2026-08-15T11:00:00Z", "taskId": 12, "title": "Undone"}),
        ],
    );

    let summaries = local.day_summaries(Local.with_ymd_and_hms(2026, 8, 15, 12, 0, 0).unwrap(), 2);
    let yesterday = summaries
        .iter()
        .find(|day| day["day"] == json!("2026-08-14"))
        .unwrap();
    assert_eq!(yesterday["completed_count"], json!(1));
    assert_eq!(yesterday["completed"][0]["task_id"], json!(11));
}

#[test]
fn an_untick_only_reaches_the_day_it_was_made_on() {
    let local = scratch();
    std::fs::write(
        local.dailies_path(),
        json!({"version": 1, "dailies": [
            {"id": "d1", "title": "Habit", "activeWeekdays": [1,2,3,4,5,6,7],
             "sortIndex": 0, "createdAt": "2026-08-01T00:00:00Z"}
        ]})
        .to_string(),
    )
    .unwrap();
    write_log(
        &local,
        &[
            json!({"kind": "dailyCompleted", "at": "2026-08-14T10:00:00Z", "taskId": 0, "title": "Habit", "dailyId": "d1"}),
            // A daily is a fresh question each morning, so this un-tick belongs to
            // the 15th and must leave the 14th ticked.
            json!({"kind": "dailyUncompleted", "at": "2026-08-15T10:00:00Z", "taskId": 0, "title": "Habit", "dailyId": "d1"}),
        ],
    );

    let summaries = local.day_summaries(Local.with_ymd_and_hms(2026, 8, 15, 12, 0, 0).unwrap(), 2);
    let done_on = |key: &str| {
        summaries
            .iter()
            .find(|day| day["day"] == json!(key))
            .unwrap()["dailies"][0]["done"]
            .clone()
    };
    assert_eq!(done_on("2026-08-14"), json!(true));
    assert_eq!(done_on("2026-08-15"), json!(false));
}

#[test]
fn a_damaged_line_costs_one_event_not_the_history() {
    let local = scratch();
    std::fs::write(
        local.daylog_path(),
        "{\"kind\": \"completed\", \"at\": \"2026-08-14T10:00:00Z\", \"taskId\": 11, \"title\": \"Kept\"}\n\
         {not json at all\n\
         {\"kind\": \"completed\", \"at\": \"2026-08-14T10:01:00Z\", \"taskId\": 12, \"title\": \"Also kept\"}\n",
    )
    .unwrap();

    let summaries = local.day_summaries(Local.with_ymd_and_hms(2026, 8, 14, 12, 0, 0).unwrap(), 1);
    assert_eq!(summaries[0]["completed_count"], json!(2));
}

#[test]
fn a_deferred_task_is_not_reported_as_unfinished() {
    let local = scratch();
    write_log(
        &local,
        &[
            json!({"kind": "planSnapshot", "at": "2026-08-14T09:00:00Z", "taskId": 0, "title": "",
               "plannedTaskIds": [11, 12, 13]}),
            json!({"kind": "completed", "at": "2026-08-14T10:00:00Z", "taskId": 11, "title": "Done"}),
            // Deliberately pushed, which is a decision rather than a failure.
            json!({"kind": "deferred", "at": "2026-08-14T11:00:00Z", "taskId": 12, "title": "Pushed"}),
        ],
    );

    let day = &local.day_summaries(Local.with_ymd_and_hms(2026, 8, 14, 12, 0, 0).unwrap(), 1)[0];
    assert_eq!(day["unfinished_task_ids"], json!([13]));
    assert_eq!(day["deferred_task_ids"], json!([12]));
}

// -- the serialised format is a cross-process interface ----------------------

#[test]
fn created_at_is_written_without_fractional_seconds() {
    // Swift decodes with `.iso8601`, which uses `.withInternetDateTime` and so
    // *rejects* fractional seconds — and `DailyDefinitionsStore.load()` turns a
    // decode failure into an empty collection. One bad timestamp written from
    // here makes every daily vanish in the app, and its next save persists that
    // emptiness over the file.
    let local = scratch();
    local
        .add_daily("Written by the CLI", None, None)
        .expect("add");

    let created_at = stored_dailies(&local)[0]["createdAt"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        created_at.len(),
        20,
        "expected yyyy-MM-ddTHH:mm:ssZ, got {created_at}"
    );
    assert!(
        created_at.ends_with('Z'),
        "expected a UTC Z suffix, got {created_at}"
    );
    assert!(
        !created_at.contains('.'),
        "fractional seconds would not decode: {created_at}"
    );
    assert!(chrono::DateTime::parse_from_rfc3339(&created_at).is_ok());
}

#[test]
fn active_weekdays_are_written_in_sorted_order() {
    // `Set` has no order on the Swift side, so an unsorted write here would
    // make every save a spurious diff in a file the user is invited to edit.
    let local = scratch();
    local
        .add_daily("Habit", Some(vec![6, 2, 4]), None)
        .expect("add");
    assert_eq!(
        stored_dailies(&local)[0]["activeWeekdays"],
        json!([2, 4, 6])
    );
}

#[test]
fn a_daily_is_appended_at_the_end_of_the_current_order() {
    let local = scratch();
    for title in ["First", "Second", "Third"] {
        local.add_daily(title, None, None).expect("add");
    }
    let indexes: Vec<i64> = stored_dailies(&local)
        .iter()
        .map(|d| d["sortIndex"].as_i64().unwrap())
        .collect();
    assert_eq!(indexes, vec![0, 1, 2]);
}

#[test]
fn archiving_keeps_the_daily_rather_than_deleting_it() {
    // History references the id, so a delete would leave past days rendering an
    // orphan instead of a title.
    let local = scratch();
    let added = local.add_daily("Habit", None, None).expect("add");
    let id = added["id"].as_str().unwrap().to_string();

    let archived = local
        .update_daily(&id, None, None, Some(true), None)
        .expect("archive");
    assert_eq!(archived["archived"], json!(true));
    assert_eq!(stored_dailies(&local).len(), 1);

    let restored = local
        .update_daily(&id, None, None, Some(false), None)
        .expect("unarchive");
    assert_eq!(restored["archived"], json!(false));
    assert!(stored_dailies(&local)[0].get("archivedAt").is_none());
}

#[test]
fn ticking_twice_is_idempotent_and_appends_only_once() {
    let local = scratch();
    let id = local.add_daily("Habit", None, None).expect("add")["id"]
        .as_str()
        .unwrap()
        .to_string();

    let first = local.set_daily(&id, true).expect("tick");
    assert_eq!(first["changed"], json!(true));
    let second = local.set_daily(&id, true).expect("tick again");
    assert_eq!(second["changed"], json!(false));

    let log = std::fs::read_to_string(local.daylog_path()).unwrap();
    assert_eq!(
        log.lines().filter(|line| !line.trim().is_empty()).count(),
        1
    );
}

#[test]
fn a_mutation_sees_what_is_on_disk_now_rather_than_an_earlier_snapshot() {
    // The app and the two other servers edit the same file. A caller that saved
    // its own in-memory copy would erase whatever they added in the meantime,
    // with no error, because from its point of view the write succeeded.
    let local = scratch();
    local.add_daily("From the CLI", None, None).expect("add");

    // Stand in for the other process: write a second daily straight to the file.
    let mut collection: Value =
        serde_json::from_str(&std::fs::read_to_string(local.dailies_path()).unwrap()).unwrap();
    collection["dailies"].as_array_mut().unwrap().push(json!({
        "id": "external", "title": "From the app", "activeWeekdays": [1,2,3,4,5,6,7],
        "sortIndex": 1, "createdAt": "2026-08-01T00:00:00Z"
    }));
    std::fs::write(local.dailies_path(), collection.to_string()).unwrap();

    local
        .add_daily("From the CLI again", None, None)
        .expect("add");

    let saved = stored_dailies(&local);
    let titles: Vec<&str> = saved.iter().map(|d| d["title"].as_str().unwrap()).collect();
    assert_eq!(
        titles,
        vec!["From the CLI", "From the app", "From the CLI again"]
    );
}

// -- rotating schedules ------------------------------------------------------

/// Writes `dailies.json` directly, so a cycle can be pinned to a fixed anchor
/// rather than to whenever the test happens to run.
fn write_dailies(local: &LocalState, dailies: &[Value]) {
    let collection = json!({ "version": 1, "dailies": dailies });
    std::fs::write(local.dailies_path(), collection.to_string()).expect("write dailies");
}

fn due_ids(local: &LocalState, on: chrono::DateTime<Local>) -> Vec<String> {
    local.dailies_snapshot(on)["dailies"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|daily| daily["due_today"] == json!(true))
        .map(|daily| daily["id"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn an_every_n_days_daily_rotates_through_the_week() {
    // Anchored on a Friday. A weekday set could never express this: by the
    // third occurrence it has walked onto Sunday.
    let local = scratch();
    write_dailies(
        &local,
        &[json!({
            "id": "cycle", "title": "Bins", "activeWeekdays": [1, 2, 3, 4, 5, 6, 7],
            "intervalDays": 3, "intervalAnchor": "2026-08-14T09:00:00Z",
            "sortIndex": 0, "createdAt": "2026-08-01T00:00:00Z",
        })],
    );

    let at = |day| Local.with_ymd_and_hms(2026, 8, day, 12, 0, 0).unwrap();
    assert_eq!(due_ids(&local, at(14)), vec!["cycle".to_string()]);
    assert!(due_ids(&local, at(15)).is_empty());
    assert!(due_ids(&local, at(16)).is_empty());
    assert_eq!(due_ids(&local, at(17)), vec!["cycle".to_string()]);
    // Two days before the anchor: the cycle runs backwards too, so the history
    // behind it isn't full of days it was "never expected on".
    assert_eq!(due_ids(&local, at(11)), vec!["cycle".to_string()]);
}

#[test]
fn a_cycle_is_labelled_by_its_length() {
    let local = scratch();
    let added = local.add_daily("Bins", None, Some(3)).expect("add");
    assert_eq!(added["schedule"], json!("Every 3 days"));
    assert_eq!(added["interval_days"], json!(3));

    let every_other = local.add_daily("Long run", None, Some(2)).expect("add");
    assert_eq!(every_other["schedule"], json!("Every other day"));
}

/// A weekday-scheduled daily reports the field as null rather than omitting it,
/// so a client can tell "not on a cycle" from "server predates cycles".
#[test]
fn a_weekday_daily_reports_a_null_interval() {
    let local = scratch();
    let added = local
        .add_daily("Standup", Some(vec![2, 3, 4, 5, 6]), None)
        .expect("add");
    assert_eq!(added["interval_days"], Value::Null);
    assert!(stored_dailies(&local)[0].get("intervalDays").is_none());
}

#[test]
fn adding_a_cycle_anchors_it_and_switching_to_weekdays_clears_it() {
    let local = scratch();
    let id = local.add_daily("Bins", None, Some(4)).expect("add")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let stored = stored_dailies(&local);
    assert_eq!(stored[0]["intervalDays"], json!(4));
    let anchor = stored[0]["intervalAnchor"].as_str().expect("anchor");
    assert!(chrono::DateTime::parse_from_rfc3339(anchor).is_ok());
    assert_eq!(
        anchor.len(),
        20,
        "expected yyyy-MM-ddTHH:mm:ssZ, got {anchor}"
    );

    // Changing the length re-spaces the cycle rather than restarting it.
    let anchor = anchor.to_string();
    local
        .update_daily(&id, None, None, None, Some(6))
        .expect("relength");
    assert_eq!(stored_dailies(&local)[0]["intervalAnchor"], json!(anchor));

    // Weekdays end the cycle outright; a stale interval left behind would keep
    // winning over the weekday set the user just chose.
    let back = local
        .update_daily(&id, None, Some(vec![2, 4]), None, None)
        .expect("weekdays");
    assert_eq!(back["schedule"], json!("Mon Wed"));
    assert_eq!(back["interval_days"], Value::Null);
    assert!(stored_dailies(&local)[0].get("intervalAnchor").is_none());
}

#[test]
fn the_two_schedules_cannot_be_combined() {
    let tools = tools_for(scratch());
    let mut arguments = Map::new();
    arguments.insert("title".into(), json!("Bins"));
    arguments.insert("active_weekdays".into(), json!([2, 4]));
    arguments.insert("interval_days".into(), json!(3));
    let Err(error) = tools.call("daily_add", &arguments) else {
        panic!("a daily with both schedules must be refused");
    };
    assert_eq!(
        error.message,
        "Pass either active_weekdays or interval_days, not both."
    );
}

#[test]
fn an_out_of_range_interval_is_refused_rather_than_stored() {
    let tools = tools_for(scratch());
    let mut arguments = Map::new();
    arguments.insert("title".into(), json!("Bins"));
    arguments.insert("interval_days".into(), json!(0));
    let Err(error) = tools.call("daily_add", &arguments) else {
        panic!("an out-of-range interval must be refused");
    };
    assert_eq!(
        error.message,
        "interval_days must be an integer between 1 and 366."
    );
}

#[test]
fn every_days_reaches_the_tool_layer_as_interval_days() {
    let cli = Cli::parse_from(["priority", "daily", "add", "Bins", "--every-days", "3"]);
    let (name, arguments) = resolve(&cli).expect("resolve");
    assert_eq!(name, "daily_add");
    assert_eq!(arguments["interval_days"], json!(3));
    assert!(arguments.get("active_weekdays").is_none());
}

#[test]
fn an_unreadable_dailies_file_reads_as_empty_rather_than_failing() {
    let local = scratch();
    std::fs::write(local.dailies_path(), "{ this is not JSON").unwrap();
    let snapshot = local.dailies_snapshot(Local::now());
    assert_eq!(snapshot["dailies"], json!([]));
}

// -- task metadata -----------------------------------------------------------

#[test]
fn the_two_priority_stores_are_read_in_their_own_encodings() {
    // `ListScopedPriorityStore` writes a JSON blob via `defaults.set(Data)`,
    // `ListScopedTaskIDStore` a plain plist dictionary. Reading either one the
    // other's way yields silently empty results.
    let local = scratch();
    let mut prefs = plist::Dictionary::new();
    prefs.insert(
        "priorityTaskIdsByParentIdByListId".into(),
        plist::Value::Data(
            json!({"999": {"0": [11, 12], "11": [13]}})
                .to_string()
                .into_bytes(),
        ),
    );
    let mut absolute = plist::Dictionary::new();
    absolute.insert(
        "999".into(),
        plist::Value::Array(vec![12.into(), 11.into()]),
    );
    prefs.insert(
        "absolutePriorityTaskIdsByListId".into(),
        plist::Value::Dictionary(absolute),
    );
    plist::Value::Dictionary(prefs)
        .to_file_binary(&local.prefs_path)
        .unwrap();

    let metadata = local.task_metadata("999");
    assert_eq!(
        metadata["absolute_priority_rank"],
        json!({"12": 1, "11": 2})
    );
    assert_eq!(
        metadata["scoped_priority_rank_by_parent_id"],
        json!({"0": {"11": 1, "12": 2}, "11": {"13": 1}})
    );
}

#[test]
fn priority_queues_drop_non_positive_and_duplicate_ids() {
    let local = scratch();
    let mut prefs = plist::Dictionary::new();
    let mut absolute = plist::Dictionary::new();
    absolute.insert(
        "999".into(),
        plist::Value::Array(vec![11.into(), 0.into(), (-3).into(), 11.into(), 12.into()]),
    );
    prefs.insert(
        "absolutePriorityTaskIdsByListId".into(),
        plist::Value::Dictionary(absolute),
    );
    plist::Value::Dictionary(prefs)
        .to_file_binary(&local.prefs_path)
        .unwrap();

    assert_eq!(
        local.task_metadata("999")["absolute_priority_rank"],
        json!({"11": 1, "12": 2})
    );
}

#[test]
fn an_empty_list_id_reads_the_offline_scope() {
    let local = scratch();
    let mut prefs = plist::Dictionary::new();
    let mut absolute = plist::Dictionary::new();
    absolute.insert("__offline__".into(), plist::Value::Array(vec![7.into()]));
    prefs.insert(
        "absolutePriorityTaskIdsByListId".into(),
        plist::Value::Dictionary(absolute),
    );
    plist::Value::Dictionary(prefs)
        .to_file_binary(&local.prefs_path)
        .unwrap();

    assert_eq!(
        local.task_metadata("")["absolute_priority_rank"],
        json!({"7": 1})
    );
}

// -- argument coercion -------------------------------------------------------

#[test]
fn a_json_integer_is_never_mistaken_for_a_boolean() {
    // The bug this pins: a Swift `NSNumber(1)` casts to `Bool` successfully, so
    // an `is Bool` guard rejected `position: 1` and `parent_task_id: 0`
    // outright. In JSON they are distinct types and must stay so.
    assert_eq!(as_optional_int(Some(&json!(1))).unwrap(), Some(1));
    assert_eq!(as_optional_int(Some(&json!(0))).unwrap(), Some(0));
    assert!(as_optional_int(Some(&json!(true))).is_err());
    assert!(as_optional_int(Some(&json!(false))).is_err());
}

#[test]
fn coercion_is_tolerant_where_clients_are_loose() {
    assert_eq!(as_optional_int(Some(&json!("42"))).unwrap(), Some(42));
    assert_eq!(as_optional_int(Some(&json!(""))).unwrap(), None);
    assert_eq!(as_optional_int(None).unwrap(), None);
    assert!(as_bool(Some(&json!("yes")), false).unwrap());
    assert!(!as_bool(Some(&json!("0")), true).unwrap());
    assert!(as_bool(None, true).unwrap());
    assert!(as_optional_int(Some(&json!(1.5))).is_err());
}

#[test]
fn weekdays_must_be_calendar_numbers_in_range() {
    assert_eq!(
        as_optional_weekdays(Some(&json!([6, 2, 2, 4]))).unwrap(),
        Some(vec![2, 4, 6])
    );
    assert_eq!(as_optional_weekdays(None).unwrap(), None);
    assert!(as_optional_weekdays(Some(&json!([0]))).is_err());
    assert!(as_optional_weekdays(Some(&json!([8]))).is_err());
    assert!(as_optional_weekdays(Some(&json!([]))).is_err());
    assert!(as_optional_weekdays(Some(&json!("mon"))).is_err());
}

// -- the CLI's own surface ---------------------------------------------------

#[test]
fn friendly_weekday_spellings_become_calendar_numbers() {
    assert_eq!(parse_weekdays("mon,wed,fri").unwrap(), vec![2, 4, 6]);
    assert_eq!(parse_weekdays("weekdays").unwrap(), vec![2, 3, 4, 5, 6]);
    assert_eq!(parse_weekdays("weekend").unwrap(), vec![1, 7]);
    assert_eq!(
        parse_weekdays("every day").unwrap(),
        vec![1, 2, 3, 4, 5, 6, 7]
    );
    assert_eq!(parse_weekdays("1,3,5").unwrap(), vec![1, 3, 5]);
    assert_eq!(parse_weekdays("Monday Tuesday").unwrap(), vec![2, 3]);
    assert!(parse_weekdays("funday").is_err());
    assert!(parse_weekdays("9").is_err());
}

fn resolved(argv: &[&str]) -> (String, Map<String, Value>) {
    resolve(&Cli::parse_from(argv)).expect("resolve")
}

#[test]
fn subcommands_map_onto_the_tools_they_claim_to_be() {
    assert_eq!(resolved(&["priority", "lists"]).0, "task_lists");
    assert_eq!(resolved(&["priority", "done", "5"]).0, "task_complete");
    assert_eq!(resolved(&["priority", "rm", "5"]).0, "task_delete");
    assert_eq!(resolved(&["priority", "dailies"]).0, "dailies_list");

    let (name, args) = resolved(&["priority", "add", "buy", "milk", "--due", "tomorrow"]);
    assert_eq!(name, "task_add");
    assert_eq!(args["content"], json!("buy milk"));
    assert_eq!(args["due"], json!("tomorrow"));
    // No parent given, so the task goes to the list root and `location` stays
    // at its default rather than being sent as "specific" with no parent.
    assert!(!args.contains_key("location"));

    let (_, args) = resolved(&["priority", "add", "sub", "--parent", "7"]);
    assert_eq!(args["location"], json!("specific"));
    assert_eq!(args["parent_task_id"], json!(7));
}

#[test]
fn reparent_without_a_parent_means_the_list_root() {
    // Omitting the key is the tool's way of saying "root"; sending 0 would work
    // too, but the absence is what the schema documents.
    let (name, args) = resolved(&["priority", "reparent", "5"]);
    assert_eq!(name, "task_reparent");
    assert!(!args.contains_key("parent_task_id"));

    let (_, args) = resolved(&["priority", "reparent", "5", "--parent", "9"]);
    assert_eq!(args["parent_task_id"], json!(9));
}

#[test]
fn archive_and_unarchive_send_the_flag_rather_than_omitting_it() {
    // `archived` absent means "leave it alone", so an unarchive that omitted
    // the key would silently do nothing.
    let (_, args) = resolved(&["priority", "daily", "update", "d1", "--archive"]);
    assert_eq!(args["archived"], json!(true));

    let (_, args) = resolved(&["priority", "daily", "update", "d1", "--unarchive"]);
    assert_eq!(args["archived"], json!(false));

    let (_, args) = resolved(&["priority", "daily", "update", "d1", "--title", "New"]);
    assert!(!args.contains_key("archived"));
}

#[test]
fn tick_off_un_ticks() {
    let (name, args) = resolved(&["priority", "daily", "tick", "d1", "--off"]);
    assert_eq!(name, "daily_tick");
    assert_eq!(args["done"], json!(false));
    assert_eq!(
        resolved(&["priority", "daily", "tick", "d1"]).1["done"],
        json!(true)
    );
}

#[test]
fn the_global_list_id_reaches_the_tool_and_call_arguments_override_it() {
    let (_, args) = resolved(&["priority", "--list-id", "123", "tasks"]);
    assert_eq!(args["list_id"], json!("123"));

    let (name, args) = resolved(&[
        "priority",
        "-l",
        "123",
        "call",
        "task_fetch",
        r#"{"list_id": "456"}"#,
    ]);
    assert_eq!(name, "task_fetch");
    assert_eq!(args["list_id"], json!("456"));
}

#[test]
fn call_rejects_arguments_that_are_not_a_json_object() {
    assert!(
        resolve(&Cli::parse_from([
            "priority",
            "call",
            "task_lists",
            "[1,2]"
        ]))
        .is_err()
    );
    assert!(resolve(&Cli::parse_from(["priority", "call", "task_lists", "nope"])).is_err());
}

#[test]
fn the_clap_definition_is_internally_consistent() {
    use clap::CommandFactory;
    Cli::command().debug_assert();
}

// -- the tool surface --------------------------------------------------------

#[test]
fn every_advertised_tool_is_actually_implemented() {
    // The failure this catches: a tool listed in `tool_definitions` but missing
    // from the dispatch table answers "Unknown tool" at the moment an assistant
    // finally reaches for it, having been told all along that it exists.
    let tools = tools_for(scratch());
    for definition in tool_definitions() {
        let name = definition["name"].as_str().expect("tool name");
        let error = tools
            .call(name, &Map::new())
            .err()
            .map(|error| error.message);
        assert!(
            !error
                .as_deref()
                .is_some_and(|message| message.starts_with("Unknown tool")),
            "{name} is advertised but not implemented"
        );
    }
}

#[test]
fn the_tool_surface_is_twenty_one_uniquely_named_tools() {
    let definitions = tool_definitions();
    let mut names: Vec<&str> = definitions
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    let total = names.len();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), total, "duplicate tool name");
    assert_eq!(total, 21);

    for definition in &definitions {
        assert!(
            definition["description"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
        );
        assert_eq!(definition["inputSchema"]["type"], json!("object"));
    }
}

#[test]
fn a_tool_result_is_a_title_a_blank_line_and_sorted_json() {
    let text = tool_result_text("Dailies", &json!({"b": 2, "a": 1}));
    assert_eq!(text, "Dailies\n\n{\n  \"a\": 1,\n  \"b\": 2\n}");
}

// -- search filtering --------------------------------------------------------

fn task(id: i64, content: &str, due: Option<&str>, tags: Value) -> Value {
    json!({"id": id, "content": content, "due": due, "tags": tags, "position": id, "parent_id": 0})
}

#[test]
fn filters_are_anded_and_an_omitted_filter_drops_out() {
    let tasks = vec![
        task(
            1,
            "Write the report #work",
            Some("2026-08-20"),
            json!(["work"]),
        ),
        task(2, "Buy milk #home", Some("2026-08-14"), json!(["home"])),
        task(3, "Write the other report", None, json!([])),
    ];

    let ids = |matches: Vec<Value>| -> Vec<i64> {
        matches
            .iter()
            .map(|task| task["id"].as_i64().unwrap())
            .collect()
    };

    assert_eq!(
        ids(filter_tasks(tasks.clone(), Some("write"), None, None)),
        vec![1, 3]
    );
    assert_eq!(
        ids(filter_tasks(tasks.clone(), None, Some("#work"), None)),
        vec![1]
    );
    assert_eq!(
        ids(filter_tasks(tasks.clone(), None, None, Some("2026-08-15"))),
        vec![2]
    );
    assert_eq!(
        ids(filter_tasks(
            tasks.clone(),
            Some("write"),
            Some("work"),
            None
        )),
        vec![1]
    );
    assert_eq!(
        ids(filter_tasks(tasks.clone(), None, None, None)),
        vec![1, 2, 3]
    );
}

#[test]
fn a_task_with_no_due_date_is_never_due_before_anything() {
    let tasks = vec![task(3, "No due date", None, json!([]))];
    assert!(filter_tasks(tasks, None, None, Some("2999-01-01")).is_empty());
}

#[test]
fn tags_are_matched_however_checkvist_happens_to_return_them() {
    // Array, dictionary, or inline in the content — matching only one of the
    // three would silently miss most tagged tasks.
    let as_array = task(1, "One", None, json!(["work"]));
    let as_dictionary = task(2, "Two", None, json!({"work": "1"}));
    let inline = task(3, "Three #work", None, json!([]));
    for candidate in [as_array, as_dictionary, inline] {
        assert_eq!(
            filter_tasks(vec![candidate], None, Some("work"), None).len(),
            1
        );
    }
}

// -- task ordering -----------------------------------------------------------

#[test]
fn tasks_come_back_parents_before_children_and_siblings_in_position_order() {
    let ordered = depth_first_tasks(vec![
        json!({"id": 3, "parent_id": 1, "position": 2, "content": "1b"}),
        json!({"id": 1, "parent_id": 0, "position": 1, "content": "1"}),
        json!({"id": 2, "parent_id": 1, "position": 1, "content": "1a"}),
        json!({"id": 4, "parent_id": 0, "position": 2, "content": "2"}),
    ]);
    let contents: Vec<&str> = ordered
        .iter()
        .map(|task| task["content"].as_str().unwrap())
        .collect();
    assert_eq!(contents, vec!["1", "1a", "1b", "2"]);
}

#[test]
fn a_parent_cycle_yields_a_partial_answer_rather_than_exhausting_the_stack() {
    // The API should never return one; a malformed list must not take the
    // process down with it.
    let ordered = depth_first_tasks(vec![
        json!({"id": 1, "parent_id": 2, "position": 1, "content": "a"}),
        json!({"id": 2, "parent_id": 1, "position": 1, "content": "b"}),
        json!({"id": 3, "parent_id": 0, "position": 1, "content": "root"}),
    ]);
    assert_eq!(
        ordered.first().and_then(|task| task["content"].as_str()),
        Some("root")
    );
}

#[test]
fn a_missing_parent_id_is_treated_as_the_root() {
    let ordered = depth_first_tasks(vec![json!({"id": 1, "position": 1, "content": "orphan"})]);
    assert_eq!(ordered.len(), 1);
}

// -- the CLI's own configuration ---------------------------------------------

fn scratch_config(contents: Option<&str>) -> Config {
    let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
    let directory =
        std::env::temp_dir().join(format!("priority-config-{}-{unique}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("scratch directory");
    let path = directory.join("config.json");
    if let Some(contents) = contents {
        std::fs::write(&path, contents).expect("write config");
    }
    Config::load_from(path)
}

#[test]
fn the_environment_beats_the_config_file() {
    // An MCP client config that sets CHECKVIST_REMOTE_KEY must keep working
    // untouched, and a one-off `CHECKVIST_LIST_ID=... priority tasks` must
    // override the stored default. This ordering is also what keeps
    // `scripts/mcp_parity_check.py` honest, since it drives every server with
    // the credentials in the environment.
    let (value, source) = choose(
        Some("from-env".into()),
        "CHECKVIST_LIST_ID",
        Some("from-file".into()),
    );
    assert_eq!(value.as_deref(), Some("from-env"));
    assert_eq!(source, Source::Environment("CHECKVIST_LIST_ID"));
}

#[test]
fn the_config_file_is_used_when_the_environment_is_unset() {
    let (value, source) = choose(None, "CHECKVIST_LIST_ID", Some("from-file".into()));
    assert_eq!(value.as_deref(), Some("from-file"));
    assert_eq!(source, Source::ConfigFile);

    let (value, source) = choose(None, "CHECKVIST_LIST_ID", None);
    assert_eq!(value, None);
    assert_eq!(source, Source::Unset);
}

#[test]
fn a_missing_config_file_is_an_empty_config_rather_than_an_error() {
    // This is the state before `auth login`, and every local command works
    // there — failing here would break `priority dailies` for a file it never
    // consults.
    let config = scratch_config(None);
    assert!(!config.exists());
    assert_eq!(
        config.resolve("NOT_A_REAL_VARIABLE", "username").1,
        Source::Unset
    );
}

#[test]
fn a_malformed_config_file_is_tolerated_rather_than_fatal() {
    let config = scratch_config(Some("{ this is not JSON"));
    assert_eq!(config.resolve("NOT_A_REAL_VARIABLE", "username").0, None);

    // A JSON document that isn't an object is equally not a config.
    let config = scratch_config(Some("[1, 2, 3]"));
    assert_eq!(config.resolve("NOT_A_REAL_VARIABLE", "username").0, None);
}

#[test]
fn blank_values_in_the_file_count_as_unset() {
    let config = scratch_config(Some(r#"{"username": "   ", "list_id": "945183"}"#));
    assert_eq!(config.resolve("NOT_A_REAL_VARIABLE", "username").0, None);
    assert_eq!(
        config
            .resolve("NOT_A_REAL_VARIABLE_EITHER", "list_id")
            .0
            .as_deref(),
        Some("945183")
    );
}

#[test]
fn the_config_file_is_written_owner_only() {
    // It holds the remote key in the clear, as CLI credential files
    // conventionally do. Mode 0600 from creation is the whole protection, and
    // it only has to leak once.
    use std::os::unix::fs::PermissionsExt;
    let mut config = scratch_config(None);
    config.set("remote_key", Some("secret"));
    config.save().expect("save");

    let mode = std::fs::metadata(&config.path)
        .expect("metadata")
        .permissions()
        .mode();
    assert_eq!(
        mode & 0o777,
        0o600,
        "config file is {:o}, expected 600",
        mode & 0o777
    );
}

#[test]
fn a_saved_config_reads_back_and_logout_removes_only_the_key() {
    let mut config = scratch_config(None);
    config.set("username", Some("you@example.com"));
    config.set("remote_key", Some("secret"));
    config.set("list_id", Some("945183"));
    config.save().expect("save");

    let reloaded = Config::load_from(config.path.clone());
    assert_eq!(
        reloaded
            .resolve("NOT_A_REAL_VARIABLE", "remote_key")
            .0
            .as_deref(),
        Some("secret")
    );

    let mut reloaded = reloaded;
    reloaded.set("remote_key", None);
    reloaded.save().expect("save");

    let after = Config::load_from(config.path.clone());
    assert_eq!(after.resolve("NOT_A_REAL_VARIABLE", "remote_key").0, None);
    // Signing out should not make you re-type the things that aren't secret.
    assert_eq!(
        after
            .resolve("NOT_A_REAL_VARIABLE", "username")
            .0
            .as_deref(),
        Some("you@example.com")
    );
    assert_eq!(
        after.resolve("NOT_A_REAL_VARIABLE", "list_id").0.as_deref(),
        Some("945183")
    );
}

#[test]
fn a_tilde_in_a_hand_edited_path_is_expanded() {
    // Nothing else in the stack expands it, and a person editing this file by
    // hand will write one.
    let config = scratch_config(Some(r#"{"store_directory": "~/Somewhere/Else"}"#));
    let (path, source) = config.resolve_path("NOT_A_REAL_VARIABLE", "store_directory");
    let path = path.expect("a path");
    assert_eq!(source, Source::ConfigFile);
    assert!(
        !path.to_string_lossy().starts_with('~'),
        "left unexpanded: {}",
        path.display()
    );
    assert!(path.ends_with("Somewhere/Else"));
}

#[test]
fn the_store_defaults_to_the_apps_own_directory() {
    // The one place the CLI and the app are deliberately joined: reading the
    // dailies and day log the app writes is why those commands exist.
    let local = LocalState::resolve(&scratch_config(None));
    assert!(
        local
            .store_directory
            .ends_with("Application Support/Priority")
    );
}

#[test]
fn the_store_can_be_pointed_elsewhere_by_the_config() {
    let config = scratch_config(Some(r#"{"store_directory": "/tmp/somewhere"}"#));
    assert_eq!(
        LocalState::resolve(&config).store_directory,
        PathBuf::from("/tmp/somewhere")
    );
}

// -- locking -----------------------------------------------------------------

#[test]
fn the_lock_file_is_a_sibling_of_the_file_it_protects() {
    // A lock on `dailies.json` itself would guard nothing: the save is atomic
    // (temp + rename), so the inode is replaced and the next process opens a
    // different file with a free lock. The path is also the interface with the
    // other two implementations — get it wrong and it stops excluding them
    // without ever failing.
    let lock = crate::lock::FileLock::protecting(&PathBuf::from("/tmp/x/dailies.json"));
    let mut held = None;
    lock.with_exclusive(|| {
        held = Some(std::fs::metadata("/tmp/x/dailies.json.lock").is_ok());
        Ok(())
    })
    .expect("lock");
    assert_eq!(held, Some(true));
}

/// The matrix write refuses while Priority is running, because macOS keeps a
/// running app's `UserDefaults` in memory and the app rewrites the whole blob
/// on its next save. Writing anyway looks like it worked and is discarded the
/// moment the user drags one card.
#[test]
fn the_matrix_write_is_declared_as_needing_the_app_closed() {
    let definition = tool_definitions()
        .into_iter()
        .find(|tool| tool["name"] == "task_matrix_set")
        .expect("task_matrix_set should be in the tool surface");
    let description = definition["description"].as_str().unwrap();
    assert!(
        description.contains("closed"),
        "the description must say the app has to be closed: {description}"
    );
    let placements = &definition["inputSchema"]["properties"]["placements"];
    assert_eq!(placements["type"], "array");
    let required = definition["inputSchema"]["required"].as_array().unwrap();
    assert!(required.iter().any(|value| value == "placements"));
}

/// `cli.rs`, `tui/` and `mcp.rs` are three front ends onto one tool table, so a
/// tool only one of them can reach is a bug in the arrangement rather than a
/// missing feature. `task_matrix_set` shipped MCP-only and needed a subcommand
/// before it was reachable from a terminal at all.
#[test]
fn the_matrix_write_is_reachable_from_the_command_line() {
    let (name, arguments) = resolve(&Cli::parse_from([
        "priority",
        "matrix",
        "71981562:5:9",
        "71981563:-3:4",
    ]))
    .expect("`priority matrix` should resolve");
    assert_eq!(name, "task_matrix_set");
    let placements = arguments["placements"].as_array().unwrap();
    assert_eq!(placements.len(), 2);
    assert_eq!(placements[0]["task_id"], 71_981_562_i64);
    assert_eq!(placements[0]["urgency"], 5.0);
    assert_eq!(placements[1]["urgency"], -3.0);
    assert_eq!(placements[1]["importance"], 4.0);
}

/// A triple that does not parse must stop the command rather than quietly
/// placing a subset — a partial write to the matrix is worse than none.
#[test]
fn a_malformed_placement_is_rejected_rather_than_guessed_at() {
    for bad in ["not-a-triple", "1:2", "1:2:3:4", "x:2:3", "1:y:3"] {
        assert!(
            resolve(&Cli::parse_from(["priority", "matrix", bad])).is_err(),
            "`{bad}` should be rejected"
        );
    }
}
