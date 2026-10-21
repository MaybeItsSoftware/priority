//! The Swift `WorkspaceKeymapTests` and `WorkspaceCommandCatalogTests` still
//! run against the Mac's wrappers as the oracle; these hold the core's own
//! rules.

use super::*;

fn resolve(json: &str) -> KeymapResolution {
    let parsed = keymap_parse(json.to_string());
    let mut resolved = keymap_resolve(parsed.bindings, workspace_command_catalog());
    let mut issues = parsed.issues;
    issues.append(&mut resolved.issues);
    resolved.issues = issues;
    resolved
}

fn entry<'a>(resolution: &'a KeymapResolution, id: &str) -> &'a CommandEntry {
    resolution
        .commands
        .iter()
        .find(|entry| entry.id == id)
        .unwrap()
}

#[test]
fn every_id_is_unique_and_every_key_is_in_the_catalogues_spelling() {
    let catalogue = workspace_command_catalog();
    let mut seen = HashSet::new();
    for entry in &catalogue {
        assert!(seen.insert(entry.id.clone()), "{} twice", entry.id);
        let all = entry.keys.iter().chain(
            entry
                .surface_keys
                .iter()
                .flat_map(|surface| surface.keys.iter()),
        );
        for key in all {
            assert_eq!(
                keymap_normalized_key(key.clone()).as_ref(),
                Ok(key),
                "{}: {key}",
                entry.id
            );
        }
    }
    for id in READS_ITS_KEY {
        assert!(seen.contains(id), "{id}");
    }
}

#[test]
fn an_empty_file_is_the_defaults() {
    for json in ["", "  \n", "[]"] {
        let resolved = resolve(json);
        assert!(resolved.issues.is_empty(), "{json:?}");
        assert_eq!(resolved.commands, workspace_command_catalog());
    }
}

#[test]
fn a_file_that_is_not_an_array_of_blocks_is_reported() {
    for json in ["[{\"bindings\": ", "{\"bindings\": {\"x\": null}}"] {
        let resolved = resolve(json);
        let kinds: Vec<_> = resolved.issues.iter().map(|issue| issue.kind).collect();
        assert_eq!(kinds, [KeymapIssueKind::UnreadableFile]);
        assert_eq!(resolved.commands, workspace_command_catalog());
    }
}

#[test]
fn a_binding_takes_the_key_from_whoever_held_it_on_that_surface() {
    let resolved =
        resolve(r#"[{"bindings": {"cmd+shift+u": "taskComplete", "cmd+t": "taskDelete"}}]"#);
    assert!(resolved.issues.is_empty(), "{:?}", resolved.issues);
    assert!(
        entry(&resolved, "taskComplete")
            .keys
            .contains(&"cmd+shift+u".to_string())
    );
    assert!(
        !entry(&resolved, "goToday")
            .keys
            .contains(&"cmd+t".to_string())
    );
    assert!(
        entry(&resolved, "taskDelete")
            .keys
            .contains(&"cmd+t".to_string())
    );
}

#[test]
fn a_context_binds_on_that_surface_and_null_there_unbinds_there() {
    let resolved = resolve(
        r#"[{"context": "Board", "bindings": {"cmd+shift+u": "taskComplete", "cmd+t": null}}]"#,
    );
    let complete = entry(&resolved, "taskComplete");
    assert_eq!(
        complete
            .surface_keys
            .iter()
            .find(|keys| keys.surface == CommandSurface::Board)
            .map(|keys| keys.keys.clone()),
        Some(vec!["cmd+shift+u".to_string()])
    );
    assert_eq!(
        resolved.unbound,
        [SurfaceKeys {
            surface: CommandSurface::Board,
            keys: vec!["cmd+t".to_string()]
        }]
    );
}

#[test]
fn null_without_a_context_unbinds_everywhere() {
    let resolved = resolve(r#"[{"bindings": {"cmd+t": null}}]"#);
    assert!(
        resolved
            .commands
            .iter()
            .all(|entry| !entry.keys.contains(&"cmd+t".to_string()))
    );
}

#[test]
fn what_cannot_apply_is_reported_and_the_rest_still_applies() {
    let resolved = resolve(
        r#"[
          {"context": "focusRunning", "bindings": {"p": null}},
          {"bindings": "x"},
          {"bindings": {"noSuchCommand": "taskDelete", "cmd+x": "noSuchCommand", "hyper+x": "taskDelete",
                        "shift+?": "taskDelete", "cmd+gg": "taskDelete", "1": "motionSetPriority"}},
          {"context": "timeline", "bindings": {"cmd+shift+u": "planBoardNewColumn"}},
          {"bindings": {"cmd+shift+u": "taskComplete"}},
          {"bindings": {"cmd+shift+u": "taskDelete"}}
        ]"#,
    );
    let kinds: Vec<_> = resolved.issues.iter().map(|issue| issue.kind).collect();
    use KeymapIssueKind::*;
    assert_eq!(
        kinds,
        [
            UnknownContext,
            MalformedBlock,
            MalformedKey,
            UnknownCommand,
            MalformedKey,
            MalformedKey,
            MalformedKey,
            NotRebindable,
            WrongSurface,
            Conflict
        ],
        "{:?}",
        resolved.issues
    );
    assert!(resolved.issues[0].message.contains("Block 1"));
    assert!(
        entry(&resolved, "taskDelete")
            .keys
            .contains(&"cmd+shift+u".to_string())
    );
}

#[test]
fn keys_are_normalised_to_the_catalogues_spelling() {
    for (raw, expected) in [
        ("Shift+Cmd+U", "cmd+shift+u"),
        ("cmd-shift-u", "cmd+shift+u"),
        ("alt+return", "option+enter"),
        ("ctrl+option+Up", "ctrl+option+up"),
        ("command+,", "cmd+comma"),
        ("esc", "escape"),
        ("backspace", "delete"),
        ("?", "?"),
        ("-", "-"),
        ("cmd+-", "cmd+-"),
        ("cmd++", "cmd++"),
        ("shift+1", "shift+1"),
        ("GH", "gh"),
        ("-2", "-2"),
    ] {
        assert_eq!(
            keymap_normalized_key(raw.to_string()),
            Ok(expected.to_string()),
            "{raw}"
        );
    }
}

#[test]
fn contexts_are_surface_names() {
    assert_eq!(
        keymap_surface_named("Board".into()),
        Some(CommandSurface::Board)
    );
    assert_eq!(
        keymap_surface_named(" timeline ".into()),
        Some(CommandSurface::Timeline)
    );
    assert_eq!(keymap_surface_named("Workspace".into()), None);
}

#[test]
fn a_chord_comes_apart_for_a_toolkit() {
    let chord = keyboard_chord("cmd+shift+z".into()).unwrap();
    assert!(chord.cmd && chord.shift && !chord.ctrl && !chord.option);
    assert_eq!(chord.key, "z");
    assert!(!chord.belongs_to_typing);
    assert_eq!(keyboard_chord("cmd++".into()).unwrap().key, "+");
    assert!(keyboard_chord("x".into()).unwrap().belongs_to_typing);
    assert!(keyboard_chord("enter".into()).unwrap().belongs_to_typing);
    assert!(!keyboard_chord("down".into()).unwrap().belongs_to_typing);
    assert!(!keyboard_chord("shift+x".into()).unwrap().belongs_to_typing);
    assert_eq!(keyboard_chord("gg".into()), None);
}

/// One-off: `TAKT_SWIFT_CATALOGUE=<dump>` compares the catalogue with a JSON
/// dump of the Swift one it was moved from.
#[test]
fn matches_a_swift_dump_when_given_one() {
    let Ok(path) = std::env::var("TAKT_SWIFT_CATALOGUE") else {
        return;
    };
    let dump: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let rows = dump["commands"].as_array().unwrap();
    let catalogue = workspace_command_catalog();
    assert_eq!(rows.len(), catalogue.len());
    for (row, entry) in rows.iter().zip(&catalogue) {
        assert_eq!(row["id"], entry.id);
        assert_eq!(row["title"], entry.title, "{}", entry.id);
        assert_eq!(row["group"], entry.group, "{}", entry.id);
        assert_eq!(row["surface"], entry.surface.name(), "{}", entry.id);
        assert_eq!(row["motion"], entry.motion, "{}", entry.id);
        assert_eq!(row["note"].as_str(), entry.note.as_deref(), "{}", entry.id);
        let keys: Vec<String> = serde_json::from_value(row["keys"].clone()).unwrap();
        assert_eq!(keys, entry.keys, "{}", entry.id);
        let surface_keys: BTreeMap<String, Vec<String>> =
            serde_json::from_value(row["surfaceKeys"].clone()).unwrap();
        let ours: BTreeMap<String, Vec<String>> = entry
            .surface_keys
            .iter()
            .map(|keys| (keys.surface.name().to_string(), keys.keys.clone()))
            .collect();
        assert_eq!(surface_keys, ours, "{}", entry.id);
    }
    let names: Vec<String> = serde_json::from_value(dump["keyNames"].clone()).unwrap();
    assert_eq!(names, KEY_NAMES.map(str::to_string));
    let mut reads: Vec<String> = serde_json::from_value(dump["readsItsKey"].clone()).unwrap();
    let mut ours = keymap_reads_its_key();
    reads.sort();
    ours.sort();
    assert_eq!(reads, ours);
}
