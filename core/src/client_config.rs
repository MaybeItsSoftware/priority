//! The configuration files Takt writes for other programs: the `takt` CLI's
//! credential store, and the entry that adds the MCP server to an AI client.
//!
//! **The CLI's store** is `~/.config/takt/config.json` (falling back to the
//! `~/.config/priority/config.json` it had before the rename). The CLI reads
//! and writes it for `takt auth`; the Mac seeds it from its own Checkvist
//! login when it sets up an MCP client, and blanks the login out again when
//! the user signs out. Both do it through this module, so the file has one
//! reading (a JSON object; blank values are absent), one encoding (pretty,
//! sorted keys, unescaped slashes, a trailing newline) and one way of being
//! written: whole, through a sibling temporary created at 0600 and renamed
//! over the target, so no reader ever sees a truncated file or one wider than
//! owner-only.
//!
//! **An MCP client's config** belongs to another program, so only the format
//! is here: the entry's shape, the merge that keeps every other key and
//! server, the rule that replaces an entry this app wrote under its old name,
//! the `claude mcp add-json` command, the snippet for a file with comments,
//! and the catalogue of clients with where their files live. Reading and
//! writing those files stays with the Mac, which owns the sandbox access and
//! leaves an existing file's mode alone.
//!
//! Replaces Swift's `TaktCLIConfigWriter`, `MCPClientConfigWriter` and
//! `MCPClientCatalog`, which keep their public types and wrap this, and the
//! file handling in `IntegrationCoordinator`. `cli/src/config.rs` reads and
//! saves through it too.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::swift_text;

/// The directory under `~/.config` the CLI keeps its settings in.
pub const CLI_CONFIG_DIRECTORY: &str = "takt";
/// What it was called before, newest first. Read while the current one is
/// missing.
pub const LEGACY_CLI_CONFIG_DIRECTORIES: &[&str] = &["priority"];
/// The file inside that directory.
pub const CLI_CONFIG_FILE_NAME: &str = "config.json";

pub const USERNAME_KEY: &str = "username";
pub const REMOTE_KEY_KEY: &str = "remote_key";
pub const LIST_ID_KEY: &str = "list_id";

/// The server name Takt registers itself under in every client.
pub const MCP_SERVER_NAME: &str = "takt";
/// Names earlier versions registered under, when the app was Priority.
pub const MCP_LEGACY_SERVER_NAMES: &[&str] = &["priority"];

/// What a merge did, or would do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConfigWriteOutcome {
    Added,
    Updated,
    /// The file already says this, so it should not be rewritten.
    Unchanged,
}

/// A merged file and what the merge did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConfigWrite {
    pub contents: String,
    pub outcome: ConfigWriteOutcome,
}

/// Why a config file was left alone.
///
/// Fields are `path`, `key` and `detail` rather than `message`, which
/// Kotlin's generated exception would clash with.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ClientConfigError {
    #[error("Connect Checkvist first — the MCP server signs in with your Checkvist credentials.")]
    MissingCredentials,
    #[error("{path} isn't valid JSON, so it wasn't touched.")]
    UnreadableConfig { path: String },
    #[error("The config has a \"{key}\" entry that isn't an object, so it wasn't touched.")]
    ServersKeyNotAnObject { key: String },
    #[error("Could not read {path}: {detail}")]
    ReadFailed { path: String, detail: String },
    #[error("Could not write {path}: {detail}")]
    WriteFailed { path: String, detail: String },
}

// MARK: - The JSON object both files are

/// A config file's text as a JSON object.
///
/// Missing, empty or all-whitespace is an empty object: that is a file
/// nobody has written yet. `None` means it is not a JSON object at all, and
/// so is not safe to rewrite.
pub fn parse_config_object(text: Option<&str>) -> Option<Map<String, Value>> {
    let trimmed = swift_text::trim(text.unwrap_or_default());
    if trimmed.is_empty() {
        return Some(Map::new());
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(values)) => Some(values),
        _ => None,
    }
}

/// Pretty-printed with two spaces, keys sorted, slashes unescaped, and a
/// trailing newline — the one encoding both files get.
pub fn encode_config_object(values: &Map<String, Value>) -> String {
    let mut text = pretty(&Value::Object(values.clone()));
    text.push('\n');
    text
}

fn pretty(value: &Value) -> String {
    // A `Value` has string keys and no non-finite numbers, so it always
    // encodes; `serde_json`'s `Map` is a `BTreeMap`, so keys come out sorted.
    serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".into())
}

/// A stored value as the CLI reads it: only a string that is not blank counts,
/// trimmed. `"username": " "` is the same as no username at all.
pub fn non_empty_string(value: Option<&Value>) -> Option<String> {
    let trimmed = swift_text::trim(value?.as_str()?);
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

// MARK: - The CLI's credential store

/// The login the Mac hands down to the CLI.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CliCredentials {
    pub username: String,
    pub remote_key: String,
    /// Optional, and only ever used to fill a gap — see [`cli_config_seeded`].
    pub list_id: String,
}

/// The CLI's config file under `config_base` (`~/.config`, or
/// `$XDG_CONFIG_HOME`), current name first and then each earlier one.
pub fn cli_config_path_candidates(config_base: &Path) -> Vec<PathBuf> {
    std::iter::once(CLI_CONFIG_DIRECTORY)
        .chain(LEGACY_CLI_CONFIG_DIRECTORIES.iter().copied())
        .map(|name| config_base.join(name).join(CLI_CONFIG_FILE_NAME))
        .collect()
}

fn home_config_base(home: &str) -> PathBuf {
    Path::new(home).join(".config")
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// Where the CLI looks by default, for a user whose home is `home`.
///
/// The CLI also honours `$PRIORITY_CONFIG_PATH` and `$XDG_CONFIG_HOME`, but
/// those live in the *client's* environment when it launches the server, not
/// in the app's, so guessing from there would be worse than the default.
#[uniffi::export]
pub fn cli_config_default_path(home: String) -> String {
    path_text(&cli_config_path_candidates(&home_config_base(&home))[0])
}

/// Where the CLI kept its config when it was called `priority`. The CLI
/// still reads it while the new one is missing, so the first seeding starts
/// from it — keeping a hand-set `base_url` — rather than from nothing.
#[uniffi::export]
pub fn cli_config_legacy_paths(home: String) -> Vec<String> {
    cli_config_path_candidates(&home_config_base(&home))
        .iter()
        .skip(1)
        .map(|path| path_text(path))
        .collect()
}

/// Merges `credentials` into the CLI's existing config.
///
/// Every other key survives — `base_url` in particular, which a user on a
/// self-hosted Checkvist will have set by hand. The app is authoritative for
/// the username and remote key (rotate in the app, every client follows);
/// `list_id` is the CLI's *default* list for terminal use, which the
/// generated MCP entry overrides per client, so it is only filled when
/// absent. `Unchanged` when the file already says this.
#[uniffi::export]
pub fn cli_config_seeded(
    credentials: CliCredentials,
    existing: Option<String>,
    config_path: String,
) -> Result<ConfigWrite, ClientConfigError> {
    let username = swift_text::trim(&credentials.username).to_string();
    let remote_key = swift_text::trim(&credentials.remote_key).to_string();
    if username.is_empty() || remote_key.is_empty() {
        return Err(ClientConfigError::MissingCredentials);
    }
    let mut values = parse_config_object(existing.as_deref())
        .ok_or(ClientConfigError::UnreadableConfig { path: config_path })?;

    let had_credentials = non_empty_string(values.get(USERNAME_KEY)).is_some()
        || non_empty_string(values.get(REMOTE_KEY_KEY)).is_some();
    let mut changed = false;
    for (key, wanted) in [(USERNAME_KEY, &username), (REMOTE_KEY_KEY, &remote_key)] {
        let stored = non_empty_string(values.get(key));
        if !swift_text::same_optional(stored.as_deref(), Some(wanted)) {
            values.insert(key.into(), Value::String(wanted.clone()));
            changed = true;
        }
    }
    let list_id = swift_text::trim(&credentials.list_id);
    if !list_id.is_empty() && non_empty_string(values.get(LIST_ID_KEY)).is_none() {
        values.insert(LIST_ID_KEY.into(), Value::String(list_id.into()));
        changed = true;
    }

    let outcome = if !changed {
        ConfigWriteOutcome::Unchanged
    } else if had_credentials {
        ConfigWriteOutcome::Updated
    } else {
        ConfigWriteOutcome::Added
    };
    Ok(ConfigWrite {
        contents: encode_config_object(&values),
        outcome,
    })
}

/// The config with the seeded username and remote key blanked to `""`, every
/// other key left alone; `None` when neither holds anything, or the file is
/// not a JSON object, so there is nothing to rewrite.
#[uniffi::export]
pub fn cli_config_cleared(
    existing: String,
    config_path: String,
) -> Result<Option<String>, ClientConfigError> {
    let trimmed = swift_text::trim(&existing);
    if trimmed.is_empty() {
        return Ok(None);
    }
    let mut values = match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(values)) => values,
        Ok(_) => return Ok(None),
        Err(_) => return Err(ClientConfigError::UnreadableConfig { path: config_path }),
    };
    let keys = [USERNAME_KEY, REMOTE_KEY_KEY];
    let holds_any = keys.iter().any(|key| {
        values
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|v| !v.is_empty())
    });
    if !holds_any {
        return Ok(None);
    }
    for key in keys {
        if let Some(value) = values.get_mut(key) {
            *value = Value::String(String::new());
        }
    }
    Ok(Some(encode_config_object(&values)))
}

/// Seeds the CLI's config under `home` from the app's login: reads the
/// current file, or failing that the legacy one (read, never written), merges
/// and writes the current path privately. Nothing is written when nothing
/// would change — the CLI may be mid-read.
#[uniffi::export]
pub fn seed_cli_config(
    home: String,
    credentials: CliCredentials,
) -> Result<ConfigWriteOutcome, ClientConfigError> {
    let candidates = cli_config_path_candidates(&home_config_base(&home));
    let target = candidates[0].clone();
    let existing = match candidates.iter().find(|path| path.exists()) {
        Some(path) => Some(read_text(path)?),
        None => None,
    };
    let seeded = cli_config_seeded(credentials, existing, path_text(&target))?;
    if seeded.outcome != ConfigWriteOutcome::Unchanged {
        write_private_file(&target, &seeded.contents)?;
    }
    Ok(seeded.outcome)
}

/// Blanks the seeded login in the CLI's current config under `home`, the
/// counterpart of [`seed_cli_config`]. Only the current path: the legacy file
/// is never written. True when the file was rewritten.
#[uniffi::export]
pub fn clear_cli_config_credentials(home: String) -> Result<bool, ClientConfigError> {
    let target = cli_config_path_candidates(&home_config_base(&home))[0].clone();
    if !target.exists() {
        return Ok(false);
    }
    let existing = read_text(&target)?;
    match cli_config_cleared(existing, path_text(&target))? {
        Some(contents) => {
            write_private_file(&target, &contents)?;
            Ok(true)
        }
        None => Ok(false),
    }
}

fn read_text(path: &Path) -> Result<String, ClientConfigError> {
    std::fs::read_to_string(path).map_err(|err| ClientConfigError::ReadFailed {
        path: path_text(path),
        detail: err.to_string(),
    })
}

/// Writes a file that holds a secret so that at no instant is there a
/// readable copy wider than 0600, and at no instant a truncated one.
///
/// A sibling temporary is created 0600, written in full and renamed over the
/// target; the rename is atomic and carries the mode with it. A symlinked
/// config (a dotfiles checkout, say) is written through to its target rather
/// than replaced by a plain file. Missing directories are created and made
/// 0700; one that already existed keeps the mode its owner gave it.
pub fn write_private_file(path: &Path, contents: &str) -> Result<(), ClientConfigError> {
    let failed = |err: std::io::Error| ClientConfigError::WriteFailed {
        path: path_text(path),
        detail: err.to_string(),
    };
    let target = match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
        }
        _ => path.to_path_buf(),
    };
    let directory = target
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));

    let missing: Vec<PathBuf> = directory
        .ancestors()
        .take_while(|ancestor| !ancestor.as_os_str().is_empty() && !ancestor.exists())
        .map(Path::to_path_buf)
        .collect();
    std::fs::create_dir_all(directory).map_err(failed)?;
    for created in missing {
        // Best effort: a slightly open directory is not worth failing over.
        let _ = std::fs::set_permissions(&created, std::fs::Permissions::from_mode(0o700));
    }

    let file_name = target
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| CLI_CONFIG_FILE_NAME.into());
    let temporary = directory.join(format!(".{file_name}.{}.tmp", uuid::Uuid::new_v4()));
    let written = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        // The umask can only narrow the mode; set it exactly.
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, &target)
    })();
    if let Err(err) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(failed(err));
    }
    Ok(())
}

// MARK: - An MCP client's entry

/// One stdio MCP server, in the shape every supported client expects.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct McpServerEntry {
    pub command: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
    /// `"stdio"` for clients that demand an explicit transport (VS Code);
    /// `None` where the presence of `command` is enough.
    pub transport_type: Option<String>,
}

/// The entry as JSON: `command` and `args`, `env` only when it holds
/// something (an empty block invites someone to put a key back in it), and
/// `type` only when the client wants it.
pub fn mcp_entry_value(entry: &McpServerEntry) -> Value {
    let mut object = Map::new();
    object.insert("command".into(), Value::String(entry.command.clone()));
    object.insert(
        "args".into(),
        Value::Array(entry.args.iter().cloned().map(Value::String).collect()),
    );
    if !entry.env.is_empty() {
        let env = entry
            .env
            .iter()
            .map(|(key, value)| (key.clone(), Value::String(value.clone())))
            .collect();
        object.insert("env".into(), Value::Object(env));
    }
    if let Some(transport) = &entry.transport_type {
        object.insert("type".into(), Value::String(transport.clone()));
    }
    Value::Object(object)
}

/// The entry as compact JSON, keys sorted.
#[uniffi::export]
pub fn mcp_entry_json(entry: McpServerEntry) -> String {
    serde_json::to_string(&mcp_entry_value(&entry)).unwrap_or_else(|_| "{}".into())
}

#[uniffi::export]
pub fn mcp_server_name() -> String {
    MCP_SERVER_NAME.into()
}

#[uniffi::export]
pub fn mcp_legacy_server_names() -> Vec<String> {
    MCP_LEGACY_SERVER_NAMES
        .iter()
        .map(|name| (*name).into())
        .collect()
}

/// Whether a server entry's command is one this app wrote under an earlier
/// name — the bundled helper, the app's own `--mcp-server` executable, or an
/// installed `priority` CLI — as opposed to something the user happens to
/// have called `priority`.
#[uniffi::export]
pub fn mcp_is_legacy_command(command: String) -> bool {
    command.ends_with("/Contents/Helpers/priority")
        || command.ends_with("/Contents/MacOS/Priority")
        || command.ends_with("/bin/priority")
}

fn is_legacy_entry(entry: &Map<String, Value>) -> bool {
    entry
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| mcp_is_legacy_command(command.into()))
}

/// Merges `entry` under `server_name` into a client's existing config,
/// keeping every other key and every other server — except an entry this app
/// wrote under one of its earlier names, which the new one replaces.
/// `Unchanged` when the entry is already identical, so a repeat install does
/// not rewrite the file. Keys come back sorted.
#[uniffi::export]
pub fn mcp_config_merged(
    entry: McpServerEntry,
    server_name: String,
    existing: Option<String>,
    servers_key: String,
    config_path: String,
) -> Result<ConfigWrite, ClientConfigError> {
    let mut root = parse_config_object(existing.as_deref())
        .ok_or(ClientConfigError::UnreadableConfig { path: config_path })?;
    let mut servers = match root.remove(&servers_key) {
        None => Map::new(),
        Some(Value::Object(servers)) => servers,
        Some(_) => return Err(ClientConfigError::ServersKeyNotAnObject { key: servers_key }),
    };

    let new_entry = mcp_entry_value(&entry);
    let mut outcome = match servers.get(&server_name) {
        Some(previous @ Value::Object(_)) if *previous == new_entry => {
            ConfigWriteOutcome::Unchanged
        }
        Some(Value::Object(_)) => ConfigWriteOutcome::Updated,
        _ => ConfigWriteOutcome::Added,
    };
    for legacy in MCP_LEGACY_SERVER_NAMES {
        if *legacy == server_name {
            continue;
        }
        if servers
            .get(*legacy)
            .and_then(Value::as_object)
            .is_some_and(is_legacy_entry)
        {
            servers.remove(*legacy);
            outcome = ConfigWriteOutcome::Updated;
        }
    }

    servers.insert(server_name, new_entry);
    root.insert(servers_key, Value::Object(servers));
    Ok(ConfigWrite {
        contents: encode_config_object(&root),
        outcome,
    })
}

/// `{ servers_key: { server_name: entry } }`, pretty-printed with no trailing
/// newline: the whole config a user pastes into an empty file.
#[uniffi::export]
pub fn mcp_config_document(
    entry: McpServerEntry,
    servers_key: String,
    server_name: String,
) -> String {
    let mut servers = Map::new();
    servers.insert(server_name, mcp_entry_value(&entry));
    let mut root = Map::new();
    root.insert(servers_key, Value::Object(servers));
    pretty(&Value::Object(root))
}

/// The `claude mcp add-json` invocation for a client that owns its config and
/// would race a direct write.
///
/// Led by a quiet `claude mcp remove` of each earlier name, so an entry added
/// when the app was called Priority is replaced. `;` rather than `&&`: on a
/// machine that never had one the remove fails, and the add must run anyway.
#[uniffi::export]
pub fn mcp_terminal_command(entry: McpServerEntry, server_name: String) -> String {
    let removals: String = MCP_LEGACY_SERVER_NAMES
        .iter()
        .filter(|legacy| **legacy != server_name)
        .map(|legacy| format!("claude mcp remove {legacy} --scope user >/dev/null 2>&1; "))
        .collect();
    format!(
        "{removals}claude mcp add-json {server_name} --scope user {}",
        single_quoted(&mcp_entry_json(entry))
    )
}

/// Wraps `value` for a POSIX shell. The config carries an email address, and
/// a broken paste is a worse failure than an ugly one.
fn single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// A fragment to paste inside an existing top-level object, for a config that
/// carries comments a rewrite would destroy: the document without its outer
/// braces, dedented once.
#[uniffi::export]
pub fn mcp_paste_snippet(
    entry: McpServerEntry,
    servers_key: String,
    server_name: String,
) -> String {
    let full = mcp_config_document(entry, servers_key, server_name);
    let lines: Vec<&str> = full.split('\n').collect();
    if lines.len() <= 2 || lines.first() != Some(&"{") || lines.last() != Some(&"}") {
        return full;
    }
    lines[1..lines.len() - 1]
        .iter()
        .map(|line| line.strip_prefix("  ").unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

// MARK: - The clients

/// How Takt can add itself to a given MCP client.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum McpClientInstallStyle {
    /// A plain JSON file that only holds MCP configuration: merge and write.
    MergeConfigFile,
    /// The client rewrites its own config continuously, so its CLI is the
    /// supported route.
    TerminalCommand,
    /// JSON with comments, which a rewrite would drop: hand over a snippet.
    PasteSnippet,
}

/// A known MCP client and everything needed to add Takt to it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct McpClientDescriptor {
    pub id: String,
    pub display_name: String,
    /// The config file, relative to the user's real home directory.
    pub config_path_components: Vec<String>,
    /// The top-level key holding the server map.
    pub servers_key: String,
    /// VS Code requires an explicit `"type": "stdio"` on each entry.
    pub requires_transport_type: bool,
    pub install_style: McpClientInstallStyle,
    /// Home-relative paths whose existence means the client is worth offering.
    pub home_relative_markers: Vec<String>,
    /// App bundle names looked for in the applications directory.
    pub application_bundle_names: Vec<String>,
    /// What the user has to do once the config lands.
    pub post_install_note: String,
}

#[allow(clippy::too_many_arguments)]
fn client(
    id: &str,
    display_name: &str,
    config_path: &[&str],
    servers_key: &str,
    requires_transport_type: bool,
    install_style: McpClientInstallStyle,
    markers: &[&str],
    bundles: &[&str],
    post_install_note: &str,
) -> McpClientDescriptor {
    let strings = |items: &[&str]| items.iter().map(|item| (*item).to_string()).collect();
    McpClientDescriptor {
        id: id.into(),
        display_name: display_name.into(),
        config_path_components: strings(config_path),
        servers_key: servers_key.into(),
        requires_transport_type,
        install_style,
        home_relative_markers: strings(markers),
        application_bundle_names: strings(bundles),
        post_install_note: post_install_note.into(),
    }
}

/// Every client Takt knows how to add itself to, in the order they are
/// offered.
#[uniffi::export]
pub fn mcp_client_catalog() -> Vec<McpClientDescriptor> {
    use McpClientInstallStyle::*;
    vec![
        // `~/.claude.json` is rewritten by Claude Code itself; a direct merge
        // would race it.
        client(
            "claude-code",
            "Claude Code",
            &[".claude.json"],
            "mcpServers",
            false,
            TerminalCommand,
            &[".claude.json", ".claude"],
            &[],
            "Run the command, then use /mcp in Claude Code to check the connection.",
        ),
        client(
            "claude-desktop",
            "Claude Desktop",
            &[
                "Library",
                "Application Support",
                "Claude",
                "claude_desktop_config.json",
            ],
            "mcpServers",
            false,
            MergeConfigFile,
            &["Library/Application Support/Claude"],
            &["Claude.app"],
            "Quit and reopen Claude Desktop to pick up the new server.",
        ),
        client(
            "cursor",
            "Cursor",
            &[".cursor", "mcp.json"],
            "mcpServers",
            false,
            MergeConfigFile,
            &[".cursor"],
            &["Cursor.app"],
            "Reload Cursor, then check Settings › MCP.",
        ),
        client(
            "windsurf",
            "Windsurf",
            &[".codeium", "windsurf", "mcp_config.json"],
            "mcpServers",
            false,
            MergeConfigFile,
            &[".codeium/windsurf"],
            &["Windsurf.app"],
            "Reload Windsurf to pick up the new server.",
        ),
        client(
            "vscode",
            "VS Code",
            &["Library", "Application Support", "Code", "User", "mcp.json"],
            "servers",
            true,
            MergeConfigFile,
            &["Library/Application Support/Code/User"],
            &["Visual Studio Code.app"],
            "Reload the VS Code window to pick up the new server.",
        ),
        // Zed's settings.json ships with explanatory comments and most users
        // add their own. Rewriting it as plain JSON would delete them all.
        client(
            "zed",
            "Zed",
            &[".config", "zed", "settings.json"],
            "context_servers",
            false,
            PasteSnippet,
            &[".config/zed"],
            &["Zed.app"],
            "Paste into settings.json — Zed picks the server up on save.",
        ),
    ]
}

/// The client's config file under `home`.
#[uniffi::export]
pub fn mcp_client_config_path(client: McpClientDescriptor, home: String) -> String {
    std::iter::once(home)
        .chain(client.config_path_components)
        .collect::<Vec<_>>()
        .join("/")
}

/// The directory that file lives in.
#[uniffi::export]
pub fn mcp_client_config_directory_path(client: McpClientDescriptor, home: String) -> String {
    let components = &client.config_path_components;
    std::iter::once(home)
        .chain(
            components[..components.len().saturating_sub(1)]
                .iter()
                .cloned(),
        )
        .collect::<Vec<_>>()
        .join("/")
}

/// The paths whose existence means `client` is on this machine: its
/// home-relative markers, then its app bundles. Any one is enough —
/// offering a client the user doesn't have costs one ignored row; hiding one
/// they do have sends them back to hand-editing JSON.
#[uniffi::export]
pub fn mcp_client_detection_paths(
    client: McpClientDescriptor,
    home: String,
    applications_directory: String,
) -> Vec<String> {
    let markers = client.home_relative_markers.iter().map(|marker| {
        std::iter::once(home.as_str())
            .chain(marker.split('/'))
            .collect::<Vec<_>>()
            .join("/")
    });
    let bundles = client
        .application_bundle_names
        .iter()
        .map(|bundle| format!("{applications_directory}/{bundle}"));
    markers.chain(bundles).collect()
}

#[cfg(test)]
mod tests;
