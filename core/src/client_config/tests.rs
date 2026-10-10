//! Ported from `corelogic-tests/TaktCLIConfigTests.swift` and
//! `MCPClientConfigTests.swift`, which still run against the Swift wrappers,
//! plus the file handling that moved here from `IntegrationCoordinator`.

use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

const CONFIG_PATH: &str = "/tmp/priority/config.json";

fn credentials() -> CliCredentials {
    CliCredentials {
        username: "you@example.com".into(),
        remote_key: "rkey".into(),
        list_id: "123".into(),
    }
}

fn seed(existing: Option<&str>) -> Result<ConfigWrite, ClientConfigError> {
    seed_with(existing, credentials())
}

fn seed_with(
    existing: Option<&str>,
    credentials: CliCredentials,
) -> Result<ConfigWrite, ClientConfigError> {
    cli_config_seeded(credentials, existing.map(Into::into), CONFIG_PATH.into())
}

fn parse(json: &str) -> Map<String, Value> {
    match serde_json::from_str::<Value>(json).expect("valid JSON") {
        Value::Object(values) => values,
        other => panic!("not an object: {other}"),
    }
}

fn text(values: &Map<String, Value>, key: &str) -> Option<String> {
    values.get(key).and_then(Value::as_str).map(Into::into)
}

// MARK: - Seeding the CLI's store

#[test]
fn seeding_a_missing_config_writes_the_credentials() {
    let result = seed(None).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    let values = parse(&result.contents);
    assert_eq!(
        text(&values, "username").as_deref(),
        Some("you@example.com")
    );
    assert_eq!(text(&values, "remote_key").as_deref(), Some("rkey"));
    assert_eq!(text(&values, "list_id").as_deref(), Some("123"));
    assert!(result.contents.ends_with("}\n"));
}

#[test]
fn an_empty_file_is_an_empty_object() {
    assert_eq!(
        seed(Some("   \n ")).unwrap().outcome,
        ConfigWriteOutcome::Added
    );
}

#[test]
fn seeding_trims_whitespace_the_way_the_cli_reads_it() {
    let padded = CliCredentials {
        username: " you@example.com ".into(),
        remote_key: " rkey ".into(),
        list_id: " 123 ".into(),
    };
    let values = parse(&seed_with(None, padded).unwrap().contents);
    assert_eq!(
        text(&values, "username").as_deref(),
        Some("you@example.com")
    );
    assert_eq!(text(&values, "remote_key").as_deref(), Some("rkey"));
    assert_eq!(text(&values, "list_id").as_deref(), Some("123"));
}

/// Someone on a self-hosted Checkvist has a `base_url` the app knows
/// nothing about.
#[test]
fn seeding_keeps_unrelated_keys() {
    let existing = r#"{
        "base_url": "https://checkvist.example.com",
        "day_log_path": "~/logs",
        "nested": {"b": [1, 2.5, true, null], "a": {}}
    }"#;
    let result = seed(Some(existing)).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    let values = parse(&result.contents);
    assert_eq!(
        text(&values, "base_url").as_deref(),
        Some("https://checkvist.example.com")
    );
    assert_eq!(text(&values, "day_log_path").as_deref(), Some("~/logs"));
    assert_eq!(values["nested"], parse(existing)["nested"]);
    assert_eq!(text(&values, "remote_key").as_deref(), Some("rkey"));
    // Slashes are not escaped, keys are sorted.
    assert!(result.contents.contains("https://checkvist.example.com"));
    let base = result.contents.find("\"base_url\"").unwrap();
    let user = result.contents.find("\"username\"").unwrap();
    assert!(base < user);
}

#[test]
fn a_repeat_seed_of_the_same_credentials_is_unchanged() {
    let first = seed(None).unwrap();
    let second = seed(Some(&first.contents)).unwrap();
    assert_eq!(second.outcome, ConfigWriteOutcome::Unchanged);
    assert_eq!(second.contents, first.contents);
}

/// Rotating the remote key in the app is what this exists for.
#[test]
fn seeding_over_a_stale_remote_key_is_an_update() {
    let result = seed(Some(
        r#"{"username": "you@example.com", "remote_key": "old-key"}"#,
    ))
    .unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Updated);
    assert_eq!(
        text(&parse(&result.contents), "remote_key").as_deref(),
        Some("rkey")
    );
}

#[test]
fn the_list_id_is_only_filled_when_absent() {
    let existing = r#"{"username": "you@example.com", "remote_key": "rkey", "list_id": "999"}"#;
    let result = seed(Some(existing)).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Unchanged);
    assert_eq!(
        text(&parse(&result.contents), "list_id").as_deref(),
        Some("999")
    );
}

#[test]
fn seeding_without_a_list_id_leaves_the_key_alone() {
    let mut no_list = credentials();
    no_list.list_id = String::new();
    let result = seed_with(None, no_list).unwrap();
    assert!(!parse(&result.contents).contains_key("list_id"));
}

#[test]
fn blank_stored_values_are_absent() {
    let result = seed(Some(
        r#"{"username": "  ", "remote_key": "", "list_id": " "}"#,
    ))
    .unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    let values = parse(&result.contents);
    assert_eq!(
        text(&values, "username").as_deref(),
        Some("you@example.com")
    );
    assert_eq!(text(&values, "list_id").as_deref(), Some("123"));
}

#[test]
fn a_malformed_or_non_object_config_is_refused() {
    let refused = Err(ClientConfigError::UnreadableConfig {
        path: CONFIG_PATH.into(),
    });
    assert_eq!(seed(Some("{ not json")), refused);
    assert_eq!(seed(Some("[1, 2, 3]")), refused);
}

#[test]
fn empty_credentials_are_refused_rather_than_written() {
    let mut blank = credentials();
    blank.username = " ".into();
    assert_eq!(
        seed_with(None, blank),
        Err(ClientConfigError::MissingCredentials)
    );
    let mut no_key = credentials();
    no_key.remote_key = String::new();
    assert_eq!(
        seed_with(None, no_key),
        Err(ClientConfigError::MissingCredentials)
    );
}

#[test]
fn the_default_path_matches_the_clis_own() {
    assert_eq!(
        cli_config_default_path("/Users/example".into()),
        "/Users/example/.config/takt/config.json"
    );
    assert_eq!(
        cli_config_legacy_paths("/Users/example".into()),
        vec!["/Users/example/.config/priority/config.json".to_string()]
    );
}

// MARK: - Clearing

#[test]
fn clearing_blanks_the_login_and_keeps_the_rest() {
    let existing =
        r#"{"username": "me", "remote_key": "k", "list_id": "9", "base_url": "https://x/y"}"#;
    let cleared = cli_config_cleared(existing.into(), CONFIG_PATH.into())
        .unwrap()
        .unwrap();
    let values = parse(&cleared);
    assert_eq!(text(&values, "username").as_deref(), Some(""));
    assert_eq!(text(&values, "remote_key").as_deref(), Some(""));
    assert_eq!(text(&values, "list_id").as_deref(), Some("9"));
    assert_eq!(text(&values, "base_url").as_deref(), Some("https://x/y"));
}

#[test]
fn clearing_a_config_with_no_login_does_nothing() {
    for existing in [
        r#"{"username": "", "list_id": "9"}"#,
        "[1]",
        "",
        r#"{"base_url": "x"}"#,
    ] {
        assert_eq!(
            cli_config_cleared(existing.into(), CONFIG_PATH.into()),
            Ok(None),
            "{existing}"
        );
    }
    assert!(cli_config_cleared("{ oops".into(), CONFIG_PATH.into()).is_err());
}

#[test]
fn clearing_only_blanks_the_keys_that_are_there() {
    let cleared = cli_config_cleared(r#"{"remote_key": "k"}"#.into(), CONFIG_PATH.into())
        .unwrap()
        .unwrap();
    assert!(!parse(&cleared).contains_key("username"));
}

// MARK: - Writing the CLI's store

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn scratch_home() -> PathBuf {
    let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
    let home = std::env::temp_dir().join(format!(
        "takt-client-config-{}-{unique}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn seeding_a_fresh_home_creates_private_directories_and_file() {
    let home = scratch_home();
    let outcome = seed_cli_config(path_text(&home), credentials()).unwrap();
    assert_eq!(outcome, ConfigWriteOutcome::Added);
    let file = home.join(".config/takt/config.json");
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(&home.join(".config/takt")), 0o700);
    assert_eq!(mode(&home.join(".config")), 0o700);
    // No temporary is left behind.
    let names: Vec<_> = std::fs::read_dir(home.join(".config/takt"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, vec![std::ffi::OsString::from("config.json")]);

    assert_eq!(
        seed_cli_config(path_text(&home), credentials()).unwrap(),
        ConfigWriteOutcome::Unchanged
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn an_existing_directory_keeps_its_mode_and_an_existing_file_is_tightened() {
    let home = scratch_home();
    let directory = home.join(".config/takt");
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
    let file = directory.join("config.json");
    std::fs::write(&file, r#"{"base_url": "https://self.hosted"}"#).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();

    assert_eq!(
        seed_cli_config(path_text(&home), credentials()).unwrap(),
        ConfigWriteOutcome::Added
    );
    assert_eq!(mode(&directory), 0o755);
    assert_eq!(mode(&file), 0o600);
    let values = parse(&std::fs::read_to_string(&file).unwrap());
    assert_eq!(
        text(&values, "base_url").as_deref(),
        Some("https://self.hosted")
    );
    let _ = std::fs::remove_dir_all(&home);
}

/// The old file is read, so a hand-set `base_url` survives the rename, and
/// left as it was.
#[test]
fn seeding_starts_from_the_legacy_file_and_never_writes_it() {
    let home = scratch_home();
    let legacy = home.join(".config/priority/config.json");
    std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    let old = r#"{"base_url": "https://old.example"}"#;
    std::fs::write(&legacy, old).unwrap();

    seed_cli_config(path_text(&home), credentials()).unwrap();
    assert_eq!(std::fs::read_to_string(&legacy).unwrap(), old);
    let values = parse(&std::fs::read_to_string(home.join(".config/takt/config.json")).unwrap());
    assert_eq!(
        text(&values, "base_url").as_deref(),
        Some("https://old.example")
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_malformed_file_on_disk_is_not_overwritten() {
    let home = scratch_home();
    let file = home.join(".config/takt/config.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, "{ oops").unwrap();
    assert!(matches!(
        seed_cli_config(path_text(&home), credentials()),
        Err(ClientConfigError::UnreadableConfig { .. })
    ));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "{ oops");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn clearing_on_disk_touches_only_the_current_file() {
    let home = scratch_home();
    assert_eq!(clear_cli_config_credentials(path_text(&home)), Ok(false));
    let legacy = home.join(".config/priority/config.json");
    std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    std::fs::write(&legacy, r#"{"remote_key": "old"}"#).unwrap();
    assert_eq!(clear_cli_config_credentials(path_text(&home)), Ok(false));

    seed_cli_config(path_text(&home), credentials()).unwrap();
    assert_eq!(clear_cli_config_credentials(path_text(&home)), Ok(true));
    let file = home.join(".config/takt/config.json");
    let values = parse(&std::fs::read_to_string(&file).unwrap());
    assert_eq!(text(&values, "remote_key").as_deref(), Some(""));
    assert_eq!(text(&values, "list_id").as_deref(), Some("123"));
    assert_eq!(mode(&file), 0o600);
    assert_eq!(clear_cli_config_credentials(path_text(&home)), Ok(false));
    assert_eq!(
        std::fs::read_to_string(&legacy).unwrap(),
        r#"{"remote_key": "old"}"#
    );
    let _ = std::fs::remove_dir_all(&home);
}

/// A config symlinked from a dotfiles checkout stays a symlink.
#[test]
fn a_symlinked_file_is_written_through() {
    let home = scratch_home();
    let real = home.join("dotfiles/takt.json");
    std::fs::create_dir_all(real.parent().unwrap()).unwrap();
    std::fs::write(&real, "{}").unwrap();
    let link = home.join(".config/takt/config.json");
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&real, &link).unwrap();

    seed_cli_config(path_text(&home), credentials()).unwrap();
    assert!(
        std::fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    let values = parse(&std::fs::read_to_string(&real).unwrap());
    assert_eq!(text(&values, "remote_key").as_deref(), Some("rkey"));
    assert_eq!(mode(&real), 0o600);
    let _ = std::fs::remove_dir_all(&home);
}

// MARK: - An MCP client's entry

fn entry() -> McpServerEntry {
    McpServerEntry {
        command: "/Applications/Priority.app/Contents/MacOS/Priority".into(),
        args: vec!["--mcp-server".into()],
        env: HashMap::from([
            ("CHECKVIST_USERNAME".into(), "you@example.com".into()),
            ("CHECKVIST_REMOTE_KEY".into(), "key".into()),
        ]),
        transport_type: None,
    }
}

fn merge(existing: Option<&str>) -> Result<ConfigWrite, ClientConfigError> {
    merge_with(existing, entry(), "mcpServers")
}

fn merge_with(
    existing: Option<&str>,
    entry: McpServerEntry,
    servers_key: &str,
) -> Result<ConfigWrite, ClientConfigError> {
    mcp_config_merged(
        entry,
        MCP_SERVER_NAME.into(),
        existing.map(Into::into),
        servers_key.into(),
        "/tmp/config.json".into(),
    )
}

fn servers(contents: &str, key: &str) -> Map<String, Value> {
    parse(contents)[key].as_object().unwrap().clone()
}

fn keys(map: &Map<String, Value>) -> Vec<&str> {
    map.keys().map(String::as_str).collect()
}

#[test]
fn merging_into_a_missing_config_adds_the_server() {
    let result = merge(None).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    let servers = servers(&result.contents, "mcpServers");
    let server = servers["takt"].as_object().unwrap();
    assert_eq!(server["command"], entry().command.as_str());
    assert_eq!(server["args"], serde_json::json!(["--mcp-server"]));
    assert!(!server.contains_key("type"));
}

#[test]
fn merging_into_an_empty_file_treats_it_as_an_empty_object() {
    assert_eq!(
        merge(Some("   \n ")).unwrap().outcome,
        ConfigWriteOutcome::Added
    );
}

#[test]
fn merging_keeps_other_servers_and_unrelated_keys() {
    let existing = r#"{
        "globalShortcut": "Cmd+Shift+X",
        "mcpServers": {
          "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
        }
    }"#;
    let result = merge(Some(existing)).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    let root = parse(&result.contents);
    assert_eq!(root["globalShortcut"], "Cmd+Shift+X");
    let servers = servers(&result.contents, "mcpServers");
    assert_eq!(keys(&servers), ["github", "takt"]);
    assert_eq!(servers["github"]["command"], "npx");
}

#[test]
fn a_repeat_merge_of_the_same_entry_is_unchanged() {
    let first = merge(None).unwrap();
    let second = merge(Some(&first.contents)).unwrap();
    assert_eq!(second.outcome, ConfigWriteOutcome::Unchanged);
    assert_eq!(second.contents, first.contents);
}

#[test]
fn merging_over_an_existing_entry_is_an_update() {
    let first = merge(None).unwrap();
    let mut rotated = entry();
    rotated
        .env
        .insert("CHECKVIST_REMOTE_KEY".into(), "rotated".into());
    let second = merge_with(Some(&first.contents), rotated, "mcpServers").unwrap();
    assert_eq!(second.outcome, ConfigWriteOutcome::Updated);
    let servers = servers(&second.contents, "mcpServers");
    assert_eq!(servers["takt"]["env"]["CHECKVIST_REMOTE_KEY"], "rotated");
}

/// A config that can't be parsed can't be safely rewritten.
#[test]
fn a_malformed_config_is_refused() {
    assert_eq!(
        merge(Some("{ not json")),
        Err(ClientConfigError::UnreadableConfig {
            path: "/tmp/config.json".into()
        })
    );
}

#[test]
fn a_servers_key_of_the_wrong_type_is_refused() {
    assert_eq!(
        merge(Some(r#"{"mcpServers": []}"#)),
        Err(ClientConfigError::ServersKeyNotAnObject {
            key: "mcpServers".into()
        })
    );
}

#[test]
fn vs_code_uses_servers_and_an_explicit_transport() {
    let mut vs_code = entry();
    vs_code.transport_type = Some("stdio".into());
    let result = merge_with(None, vs_code, "servers").unwrap();
    let root = parse(&result.contents);
    assert!(!root.contains_key("mcpServers"));
    assert_eq!(root["servers"]["takt"]["type"], "stdio");
}

#[test]
fn an_empty_environment_is_omitted() {
    let mut bare = entry();
    bare.env.clear();
    let value = mcp_entry_value(&bare);
    assert!(value.get("env").is_none());
    assert_eq!(
        mcp_entry_json(bare),
        r#"{"args":["--mcp-server"],"command":"/Applications/Priority.app/Contents/MacOS/Priority"}"#
    );
}

// MARK: - The rename from Priority

#[test]
fn an_entry_written_under_the_old_name_is_replaced() {
    let existing = r#"{
        "mcpServers": {
          "github": { "command": "npx", "args": [] },
          "priority": { "command": "/Applications/Priority.app/Contents/Helpers/priority", "args": ["mcp"] }
        }
    }"#;
    let result = merge(Some(existing)).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Updated);
    assert_eq!(
        keys(&servers(&result.contents, "mcpServers")),
        ["github", "takt"]
    );
}

#[test]
fn an_unrelated_entry_named_priority_is_left_alone() {
    let existing =
        r#"{ "mcpServers": { "priority": { "command": "/opt/other/server", "args": [] } } }"#;
    let result = merge(Some(existing)).unwrap();
    assert_eq!(result.outcome, ConfigWriteOutcome::Added);
    assert_eq!(
        keys(&servers(&result.contents, "mcpServers")),
        ["priority", "takt"]
    );
}

#[test]
fn legacy_commands_are_recognised_by_their_suffix() {
    for command in [
        "/Applications/Priority.app/Contents/Helpers/priority",
        "/Applications/Priority.app/Contents/MacOS/Priority",
        "/Users/me/.local/bin/priority",
    ] {
        assert!(mcp_is_legacy_command(command.into()), "{command}");
    }
    for command in [
        "/opt/other/server",
        "priority",
        "/Applications/Takt.app/Contents/Helpers/takt",
    ] {
        assert!(!mcp_is_legacy_command(command.into()), "{command}");
    }
}

// MARK: - Terminal command and paste snippet

#[test]
fn the_terminal_command_is_a_single_shell_safe_line() {
    let command = mcp_terminal_command(entry(), MCP_SERVER_NAME.into());
    let removal = "claude mcp remove priority --scope user >/dev/null 2>&1; ";
    let add = "claude mcp add-json takt --scope user '";
    let prefix = format!("{removal}{add}");
    assert!(command.starts_with(&prefix), "{command}");
    assert!(command.ends_with('\''));
    assert!(!command.contains('\n'));
    let json = &command[prefix.len()..command.len() - 1];
    assert_eq!(parse(json)["command"], entry().command.as_str());
}

#[test]
fn the_terminal_command_escapes_single_quotes() {
    let awkward = McpServerEntry {
        command: "/bin/true".into(),
        args: vec![],
        env: HashMap::from([("CHECKVIST_USERNAME".into(), "o'brien@example.com".into())]),
        transport_type: None,
    };
    assert!(mcp_terminal_command(awkward, MCP_SERVER_NAME.into()).contains(r"'\''"));
}

#[test]
fn the_terminal_command_for_the_old_name_removes_nothing() {
    let command = mcp_terminal_command(entry(), "priority".into());
    assert!(command.starts_with("claude mcp add-json priority --scope user '"));
}

#[test]
fn the_paste_snippet_is_a_fragment_without_outer_braces() {
    let snippet = mcp_paste_snippet(entry(), "context_servers".into(), MCP_SERVER_NAME.into());
    assert!(snippet.starts_with("\"context_servers\""), "{snippet}");
    let root = parse(&format!("{{{snippet}}}"));
    assert_eq!(
        root["context_servers"]["takt"]["command"],
        entry().command.as_str()
    );
}

#[test]
fn the_document_is_the_whole_config_without_a_trailing_newline() {
    let document = mcp_config_document(entry(), "mcpServers".into(), MCP_SERVER_NAME.into());
    assert!(document.starts_with("{\n  \"mcpServers\": {\n    \"takt\": {"));
    assert!(document.ends_with('}'));
    assert_eq!(
        parse(&document)["mcpServers"]["takt"],
        mcp_entry_value(&entry())
    );
}

// MARK: - The clients

fn catalog_client(id: &str) -> McpClientDescriptor {
    mcp_client_catalog()
        .into_iter()
        .find(|client| client.id == id)
        .unwrap()
}

fn detected(home: &str, present: &[&str]) -> Vec<String> {
    mcp_client_catalog()
        .into_iter()
        .filter(|client| {
            mcp_client_detection_paths(client.clone(), home.into(), "/Applications".into())
                .iter()
                .any(|path| present.contains(&path.as_str()))
        })
        .map(|client| client.id)
        .collect()
}

#[test]
fn detection_matches_home_markers_and_application_bundles() {
    assert_eq!(
        detected(
            "/Users/test",
            &["/Users/test/.claude.json", "/Applications/Cursor.app"]
        ),
        ["claude-code", "cursor"]
    );
    assert_eq!(
        detected(
            "/Users/test",
            &["/Users/test/Library/Application Support/Code/User"]
        ),
        ["vscode"]
    );
}

#[test]
fn detection_finds_nothing_on_a_bare_machine() {
    assert!(detected("/Users/test", &[]).is_empty());
}

#[test]
fn the_catalogue_is_in_the_order_it_is_offered() {
    let ids: Vec<String> = mcp_client_catalog().into_iter().map(|c| c.id).collect();
    assert_eq!(
        ids,
        [
            "claude-code",
            "claude-desktop",
            "cursor",
            "windsurf",
            "vscode",
            "zed"
        ]
    );
}

/// `~/.claude.json` is rewritten by Claude Code itself, and Zed's settings
/// carry comments; neither is ever edited directly.
#[test]
fn claude_code_and_zed_are_never_edited_directly() {
    assert_eq!(
        catalog_client("claude-code").install_style,
        McpClientInstallStyle::TerminalCommand
    );
    assert_eq!(
        catalog_client("zed").install_style,
        McpClientInstallStyle::PasteSnippet
    );
    let only_vs_code: Vec<String> = mcp_client_catalog()
        .into_iter()
        .filter(|client| client.requires_transport_type)
        .map(|client| client.id)
        .collect();
    assert_eq!(only_vs_code, ["vscode"]);
}

#[test]
fn a_clients_config_path_is_under_the_home_directory() {
    let desktop = catalog_client("claude-desktop");
    assert_eq!(
        mcp_client_config_path(desktop.clone(), "/Users/test".into()),
        "/Users/test/Library/Application Support/Claude/claude_desktop_config.json"
    );
    assert_eq!(
        mcp_client_config_directory_path(desktop, "/Users/test".into()),
        "/Users/test/Library/Application Support/Claude"
    );
    assert_eq!(
        mcp_client_config_directory_path(catalog_client("claude-code"), "/Users/test".into()),
        "/Users/test"
    );
}
