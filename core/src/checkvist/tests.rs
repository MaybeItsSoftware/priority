//! Ported from the Mac's `CheckvistModels` decoding, `CheckvistSession`'s
//! token reading and `CheckvistTaskRepository.depthFirstTasks`, and from the
//! CLI's `checkvist.rs`, whose request shapes the core now makes.

use super::*;
use serde_json::json;

fn request(call: CheckvistCall, token: Option<&str>) -> CheckvistHttpRequest {
    checkvist_request(
        "https://checkvist.com/".into(),
        call,
        token.map(str::to_string),
        "Takt/1.0".into(),
    )
    .expect("a valid call")
}

fn header<'a>(request: &'a CheckvistHttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|header| header.name == name)
        .map(|header| header.value.as_str())
}

fn body(request: &CheckvistHttpRequest) -> Value {
    serde_json::from_str(request.body.as_deref().expect("a body")).unwrap()
}

#[test]
fn login_posts_the_credentials_without_a_token() {
    let login = request(
        CheckvistCall::Login {
            username: "me@example.com".into(),
            remote_key: "key".into(),
        },
        None,
    );
    assert_eq!(login.method, "POST");
    assert_eq!(login.url, "https://checkvist.com/auth/login.json");
    assert_eq!(
        body(&login),
        json!({ "username": "me@example.com", "remote_key": "key" })
    );
    assert_eq!(header(&login, "X-Client-Token"), None);
    assert_eq!(header(&login, "Content-Type"), Some("application/json"));
    assert_eq!(header(&login, "User-Agent"), Some("Takt/1.0"));
}

#[test]
fn reads_carry_the_token_and_no_body() {
    let lists = request(CheckvistCall::Lists, Some("tok"));
    assert_eq!(
        (lists.method.as_str(), lists.url.as_str()),
        ("GET", "https://checkvist.com/checklists.json")
    );
    assert_eq!(header(&lists, "X-Client-Token"), Some("tok"));
    assert_eq!(header(&lists, "Content-Type"), None);
    assert_eq!(lists.body, None);

    let tasks = request(
        CheckvistCall::Tasks {
            list_id: "42".into(),
            with_notes: true,
        },
        Some("tok"),
    );
    assert_eq!(
        tasks.url,
        "https://checkvist.com/checklists/42/tasks.json?with_notes=true"
    );
}

#[test]
fn a_list_id_must_be_a_number() {
    for bad in ["", "../1", "1?x=2", "abc"] {
        let refused = checkvist_request(
            DEFAULT_BASE_URL.into(),
            CheckvistCall::DeleteTask {
                list_id: bad.into(),
                task_id: 1,
            },
            None,
            String::new(),
        );
        assert!(refused.is_err(), "{bad:?} was accepted");
    }
}

#[test]
fn creating_a_task_trims_it_and_parses_only_when_asked() {
    let created = request(
        CheckvistCall::CreateTask {
            list_id: "7".into(),
            content: "  Write #report  ".into(),
            parent_id: Some(3),
            position: Some(1),
            due: Some("2026-10-11".into()),
            tags: None,
            priority: None,
            parse: false,
        },
        Some("tok"),
    );
    assert_eq!(created.url, "https://checkvist.com/checklists/7/tasks.json");
    assert_eq!(
        body(&created),
        json!({ "task": {
            "content": "Write #report", "parent_id": 3, "position": 1, "due_date": "2026-10-11"
        } })
    );

    let parsed = request(
        CheckvistCall::CreateTask {
            list_id: "7".into(),
            content: "x".into(),
            parent_id: None,
            position: None,
            due: None,
            tags: None,
            priority: None,
            parse: true,
        },
        None,
    );
    assert_eq!(
        parsed.url,
        "https://checkvist.com/checklists/7/tasks.json?parse=true"
    );

    let empty = checkvist_request(
        DEFAULT_BASE_URL.into(),
        CheckvistCall::CreateTask {
            list_id: "7".into(),
            content: "   ".into(),
            parent_id: None,
            position: None,
            due: None,
            tags: None,
            priority: None,
            parse: false,
        },
        None,
        String::new(),
    );
    assert!(empty.is_err());
}

#[test]
fn updates_put_only_what_changes() {
    let update = request(
        CheckvistCall::UpdateTask {
            list_id: "7".into(),
            task_id: 9,
            content: Some("New".into()),
            due: Some(String::new()),
            tags: None,
        },
        Some("tok"),
    );
    assert_eq!(update.method, "PUT");
    assert_eq!(
        update.url,
        "https://checkvist.com/checklists/7/tasks/9.json"
    );
    assert_eq!(
        body(&update),
        json!({ "task": { "content": "New", "due_date": "" } })
    );

    let nothing = checkvist_request(
        DEFAULT_BASE_URL.into(),
        CheckvistCall::UpdateTask {
            list_id: "7".into(),
            task_id: 9,
            content: None,
            due: None,
            tags: None,
        },
        None,
        String::new(),
    );
    assert!(nothing.is_err());
}

#[test]
fn reparenting_to_the_root_sends_an_explicit_null() {
    let root = request(
        CheckvistCall::ReparentTask {
            list_id: "7".into(),
            task_id: 9,
            parent_id: None,
        },
        None,
    );
    assert_eq!(body(&root), json!({ "task": { "parent_id": null } }));
    let moved = request(
        CheckvistCall::MoveTask {
            list_id: "7".into(),
            task_id: 9,
            position: 2,
        },
        None,
    );
    assert_eq!(body(&moved), json!({ "task": { "position": 2 } }));
}

#[test]
fn actions_notes_lists_and_deletes() {
    let close = request(
        CheckvistCall::TaskAction {
            list_id: "7".into(),
            task_id: 9,
            action: "close".into(),
        },
        None,
    );
    assert_eq!(
        (close.method.as_str(), close.url.as_str()),
        (
            "POST",
            "https://checkvist.com/checklists/7/tasks/9/close.json"
        )
    );
    assert!(
        checkvist_request(
            DEFAULT_BASE_URL.into(),
            CheckvistCall::TaskAction {
                list_id: "7".into(),
                task_id: 9,
                action: "explode".into()
            },
            None,
            String::new()
        )
        .is_err()
    );
    let note = request(
        CheckvistCall::AddNote {
            list_id: "7".into(),
            task_id: 9,
            comment: "hi".into(),
        },
        None,
    );
    assert_eq!(
        note.url,
        "https://checkvist.com/checklists/7/tasks/9/comments.json"
    );
    assert_eq!(body(&note), json!({ "comment": { "comment": "hi" } }));
    let list = request(
        CheckvistCall::CreateList {
            name: " Work ".into(),
        },
        None,
    );
    assert_eq!(body(&list), json!({ "checklist": { "name": "Work" } }));
    let delete = request(
        CheckvistCall::DeleteTask {
            list_id: "7".into(),
            task_id: 9,
        },
        None,
    );
    assert_eq!(delete.method, "DELETE");
    assert_eq!(delete.body, None);
}

#[test]
fn a_blank_base_url_is_checkvist_and_a_custom_one_is_kept() {
    let blank = checkvist_request(" ".into(), CheckvistCall::Lists, None, String::new()).unwrap();
    assert_eq!(blank.url, "https://checkvist.com/checklists.json");
    let staging = checkvist_request(
        "http://localhost:8080//".into(),
        CheckvistCall::Lists,
        None,
        String::new(),
    )
    .unwrap();
    assert_eq!(staging.url, "http://localhost:8080/checklists.json");
    assert_eq!(header(&staging, "User-Agent"), None);
}

#[test]
fn the_login_token_is_read_from_an_object_or_a_bare_string() {
    assert_eq!(
        checkvist_login_token(r#"{"token":"abc"}"#.into()).as_deref(),
        Some("abc")
    );
    assert_eq!(
        checkvist_login_token("\"abc\"\n".into()).as_deref(),
        Some("abc")
    );
    assert_eq!(checkvist_login_token("abc".into()).as_deref(), Some("abc"));
    assert_eq!(checkvist_login_token(r#"{"token":"  "}"#.into()), None);
    assert_eq!(checkvist_login_token(r#"{"other":"x"}"#.into()), None);
    assert_eq!(checkvist_login_token(String::new()), None);
    assert_eq!(checkvist_login_token("\"\"".into()), None);
}

#[test]
fn archived_lists_are_left_out() {
    let lists = checkvist_lists(
        r#"[{"id":1,"name":"Work","archived":false,"read_only":true},
            {"id":2,"name":"Old","archived":true},
            {"id":"3","name":"Home"}, 7]"#
            .into(),
    )
    .unwrap();
    assert_eq!(
        lists,
        vec![
            CheckvistListRow {
                id: 1,
                name: "Work".into(),
                archived: Some(false),
                read_only: Some(true)
            },
            CheckvistListRow {
                id: 3,
                name: "Home".into(),
                archived: None,
                read_only: None
            },
        ]
    );
    assert!(checkvist_lists(r#"{"error":"no"}"#.into()).is_err());
}

#[test]
fn a_task_is_read_whatever_types_checkvist_chose() {
    let task = task_row(&json!({
        "id": "12", "text": "Fallback content", "status": "1", "position": 2.0,
        "parent_id": null, "level": 1, "updated_at": 1700000000,
        "notes": [
            { "id": 4, "comment": "From the API", "created_at": "2026-01-01" },
            "A bare note",
            { "content": "Content key" }
        ]
    }))
    .unwrap();
    assert_eq!(task.id, 12);
    assert_eq!(task.content, "Fallback content");
    assert_eq!(task.status, 1);
    assert_eq!(task.position, Some(2));
    assert_eq!(task.parent_id, None);
    assert_eq!(task.updated_at.as_deref(), Some("1700000000"));
    let notes: Vec<&str> = task
        .notes
        .as_ref()
        .unwrap()
        .iter()
        .map(|note| note.content.as_str())
        .collect();
    assert_eq!(notes, ["From the API", "A bare note", "Content key"]);
    assert_eq!(task.notes.as_ref().unwrap()[0].id, Some(4));

    assert!(task_row(&json!({ "content": "no id" })).is_none());
}

#[test]
fn a_due_date_is_found_under_any_name_for_one() {
    let due = |value: Value| task_row(&value).unwrap().due;
    assert_eq!(
        due(json!({ "id": 1, "due": "2026-01-02" })).as_deref(),
        Some("2026-01-02")
    );
    assert_eq!(
        due(json!({ "id": 1, "due_date": "2026-01-03" })).as_deref(),
        Some("2026-01-03")
    );
    assert_eq!(
        due(json!({ "id": 1, "deadline": "2026-01-04" })).as_deref(),
        Some("2026-01-04")
    );
    assert_eq!(
        due(json!({ "id": 1, "due_user_ts": "2026-01-05", "other": "x" })).as_deref(),
        Some("2026-01-05")
    );
    assert_eq!(due(json!({ "id": 1, "due_user_ts": "  " })), None);
    assert_eq!(due(json!({ "id": 1, "due": 1.5 })).as_deref(), Some("1.5"));
    assert_eq!(due(json!({ "id": 1, "due": 2.0 })).as_deref(), Some("2.0"));
}

#[test]
fn single_and_string_notes_become_one_note() {
    let one = task_row(&json!({ "id": 1, "notes": { "note": "Only" } })).unwrap();
    assert_eq!(one.notes.unwrap()[0].content, "Only");
    let text = task_row(&json!({ "id": 1, "notes": "Plain" })).unwrap();
    assert_eq!(text.notes.unwrap()[0].content, "Plain");
    let broken = task_row(&json!({ "id": 1, "notes": [1, 2] })).unwrap();
    assert_eq!(broken.notes, None);
}

#[test]
fn tasks_come_parents_first_with_siblings_by_position() {
    let body = r#"[
        {"id":3,"content":"B","status":0,"parent_id":0,"position":2},
        {"id":1,"content":"A","status":0,"parent_id":0,"position":1},
        {"id":4,"content":"A2","status":0,"parent_id":1,"position":2},
        {"id":2,"content":"A1","status":0,"parent_id":1,"position":1},
        {"id":5,"content":"Done","status":1,"parent_id":0,"position":3},
        {"id":7,"content":"Orphan","status":0,"parent_id":99,"position":1},
        {"id":6,"content":"Orphan2","status":0,"parent_id":50,"position":1}
    ]"#;
    let open: Vec<i64> = checkvist_tasks(body.into(), false)
        .unwrap()
        .iter()
        .map(|task| task.id)
        .collect();
    assert_eq!(open, [1, 2, 4, 3, 6, 7]);
    let all: Vec<i64> = checkvist_tasks(body.into(), true)
        .unwrap()
        .iter()
        .map(|task| task.id)
        .collect();
    assert_eq!(all, [1, 2, 4, 3, 5, 6, 7]);
}

#[test]
fn a_parent_cycle_does_not_recurse_forever() {
    let order = depth_first_order(&[(1, 2, 0), (2, 1, 0), (3, 0, 0)]);
    assert_eq!(order, [2]);
    let cycle_off_an_orphan = depth_first_order(&[(1, 9, 0), (2, 1, 0), (1, 2, 1)]);
    assert!(cycle_off_an_orphan.len() <= 3);
}

#[test]
fn a_created_task_is_read_bare_or_wrapped() {
    for body in [
        r#"{"id":5,"content":"x"}"#,
        r#"{"task":{"id":5,"content":"x"}}"#,
        r#"{"tasks":[{"id":5,"content":"x"}]}"#,
        r#"[{"id":5,"content":"x"}]"#,
    ] {
        assert_eq!(
            checkvist_created_task(body.into()).map(|task| task.id),
            Some(5),
            "{body}"
        );
    }
    assert_eq!(checkvist_created_task("true".into()), None);
    assert_eq!(
        checkvist_created_list(r#"{"checklist":{"id":8,"name":"New"}}"#.into()).map(|list| list.id),
        Some(8)
    );
    assert_eq!(
        checkvist_created_list(r#"{"id":8,"name":"New"}"#.into()).map(|list| list.id),
        Some(8)
    );
}

#[test]
fn a_project_is_its_root_and_every_descendant() {
    let tasks = vec![
        json!({"id": 1, "parent_id": 0}),
        json!({"id": 3, "parent_id": 2}),
        json!({"id": 2, "parent_id": 1}),
        json!({"id": 4, "parent_id": 0}),
    ];
    let ids: Vec<i64> = project_tasks(&tasks, 1)
        .unwrap()
        .iter()
        .map(|task| task["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, [1, 2, 3]);
    assert!(project_tasks(&tasks, 9).is_err());
}

#[test]
fn import_seeds_are_unique_prefixed_and_carry_notes() {
    let task = |id, parent: Option<i64>, position, status| CheckvistTaskRow {
        id,
        content: format!("T{id}"),
        status,
        due: None,
        position: Some(position),
        parent_id: parent,
        level: None,
        notes: Some(vec![
            CheckvistNoteRow {
                id: None,
                content: "one".into(),
                created_at: None,
                updated_at: None,
            },
            CheckvistNoteRow {
                id: None,
                content: "two".into(),
                created_at: None,
                updated_at: None,
            },
        ]),
        updated_at: None,
    };
    let seeds = checkvist_import_seeds(
        "checkvist:7:".into(),
        vec![
            task(2, Some(1), 1, 1),
            task(1, None, 2, 0),
            task(3, None, 1, 2),
            task(1, None, 9, 0),
        ],
    );
    let ids: Vec<&str> = seeds.iter().map(|seed| seed.source_id.as_str()).collect();
    assert_eq!(ids, ["checkvist:7:3", "checkvist:7:1", "checkvist:7:2"]);
    assert_eq!(seeds[2].parent_source_id.as_deref(), Some("checkvist:7:1"));
    assert_eq!(
        seeds
            .iter()
            .map(|seed| seed.status.as_str())
            .collect::<Vec<_>>(),
        ["cancelled", "open", "completed"]
    );
    assert_eq!(seeds[1].notes, "one\n\ntwo");
    assert_eq!(seeds[1].sort_order, 2);
}
