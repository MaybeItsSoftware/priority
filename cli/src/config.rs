//! The CLI's own configuration, kept deliberately apart from the app's.
//!
//! `takt` is a peer of the macOS app, not a front end for it, and its
//! credentials live accordingly: in `~/.config/takt/config.json` rather
//! than in the app's login-keychain item or its preferences plist. Signing in
//! here does not sign you in there, and vice versa — which is the point. The
//! app's storage is reachable only by something carrying the app's code
//! signature, so a CLI that depended on it would work or not depending on how
//! the app happened to be built and signed that day.
//!
//! Precedence is the conventional one: **environment beats file**. An MCP
//! client config that sets `CHECKVIST_REMOTE_KEY` therefore keeps working
//! untouched, and a one-off `CHECKVIST_LIST_ID=... takt tasks` overrides
//! the stored default without editing anything.
//!
//! The file is *not* read when the corresponding environment variable is set.
//! That is what lets `scripts/mcp_smoke_check.py` drive the server against a
//! throwaway `HOME` with fake credentials in the environment, and be sure this
//! file is not quietly answering instead.

//!
//! The file's format — what counts as a config, how it is encoded, where it
//! lives under `~/.config` — and the private, atomic write are the core's
//! (`takt_core::client_config`), which the app uses too when it seeds this
//! file from its own login. So there is one reading and one writing of it.

use crate::error::{Result, ToolError};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use takt_core::client_config;

/// The app's directory under `~/Library/Application Support`.
pub const APP_SUPPORT_DIRECTORY: &str = "Takt";
/// Its earlier names, newest first. The app copies these forward on its
/// first launch under the new name; until then, they are where the data is.
pub const LEGACY_APP_SUPPORT_DIRECTORIES: &[&str] = &["Priority"];

/// The first candidate that exists on disk, or the first candidate if none do.
///
/// The first is always the current name, so a fresh machine is pointed at the
/// new location and an old one at whatever it actually has.
pub fn first_existing(candidates: Vec<PathBuf>) -> PathBuf {
    candidates
        .iter()
        .find(|path| path.exists())
        .or(candidates.first())
        .cloned()
        .unwrap_or_default()
}

/// Where a value actually came from, so `auth status` can say rather than imply.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Source {
    Environment(&'static str),
    ConfigFile,
    Default,
    Unset,
}

impl Source {
    pub fn describe(self) -> String {
        match self {
            Source::Environment(name) => format!("${name}"),
            Source::ConfigFile => "config file".into(),
            Source::Default => "default".into(),
            Source::Unset => "not set".into(),
        }
    }
}

pub struct Config {
    pub path: PathBuf,
    values: Map<String, Value>,
    /// The file exists but is not a JSON object. Read as empty so the local
    /// commands keep working; refused by [`Config::save`] so a typo in a
    /// hand-edited file is not quietly replaced with whatever was in memory.
    malformed: bool,
}

impl Config {
    /// `$PRIORITY_CONFIG_PATH`, else `$XDG_CONFIG_HOME/takt/config.json`,
    /// else `~/.config/takt/config.json`.
    ///
    /// The CLI was called `priority` before the product became Takt, so when
    /// the new file doesn't exist yet but `…/priority/config.json` does, that is
    /// the one read — and the one written back, so a sign-in made before the
    /// rename keeps working rather than being silently forgotten. Running
    /// `takt auth login` against a fresh machine writes the new path.
    ///
    /// The explicit override exists for tests and for the smoke check, which
    /// must not read whatever the developer happens to have configured.
    pub fn default_path() -> PathBuf {
        if let Some(path) = non_empty_env("PRIORITY_CONFIG_PATH") {
            return PathBuf::from(path);
        }
        let base = non_empty_env("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config")
            });
        first_existing(client_config::cli_config_path_candidates(&base))
    }

    /// A missing, unreadable or empty file is an empty config, not an error —
    /// that is the state before `takt auth login`, and every local command
    /// works there. A *malformed* file is also tolerated rather than fatal, because
    /// the dailies and day-log commands have no business failing over a
    /// credential file they never consult. It is remembered as malformed,
    /// though, so that saving refuses to overwrite it.
    pub fn load() -> Self {
        Self::load_from(Self::default_path())
    }

    pub fn load_from(path: PathBuf) -> Self {
        let (values, malformed) = match std::fs::read_to_string(&path) {
            Err(_) => (Map::new(), false),
            Ok(text) => match client_config::parse_config_object(Some(&text)) {
                Some(values) => (values, false),
                None => (Map::new(), true),
            },
        };
        Config {
            path,
            values,
            malformed,
        }
    }

    pub fn exists(&self) -> bool {
        self.path.exists()
    }

    /// Whether the file on disk was unreadable as a JSON object.
    pub fn is_malformed(&self) -> bool {
        self.malformed
    }

    fn string(&self, key: &str) -> Option<String> {
        client_config::non_empty_string(self.values.get(key))
    }

    /// The environment first, then the file. Returns where it came from too,
    /// because "why is it using the wrong list?" is otherwise a guessing game.
    pub fn resolve(&self, env_key: &'static str, config_key: &str) -> (Option<String>, Source) {
        choose(non_empty_env(env_key), env_key, self.string(config_key))
    }

    pub fn resolve_path(
        &self,
        env_key: &'static str,
        config_key: &str,
    ) -> (Option<PathBuf>, Source) {
        let (value, source) = self.resolve(env_key, config_key);
        (
            value.map(|value| PathBuf::from(expand_tilde(&value))),
            source,
        )
    }

    pub fn set(&mut self, key: &str, value: Option<&str>) {
        match value.map(str::trim).filter(|value| !value.is_empty()) {
            Some(value) => {
                self.values.insert(key.into(), json!(value));
            }
            None => {
                self.values.remove(key);
            }
        }
    }

    /// Writes the whole file privately: a sibling temporary created 0600 is
    /// renamed over it, so there is never a moment when the remote key sits
    /// in a file wider than owner-only, nor a truncated file for the app or
    /// another `takt` to read. A directory this makes is 0700; one a person
    /// chose (`PRIORITY_CONFIG_PATH`, `XDG_CONFIG_HOME`) or that already
    /// existed keeps its mode. See `client_config::write_private_file`.
    ///
    /// Refuses to overwrite a file that exists but could not be read as a
    /// JSON object: the values in memory are empty plus whatever was just
    /// set, and writing them would silently discard whatever the file held.
    pub fn save(&self) -> Result<()> {
        if self.malformed {
            return Err(ToolError::new(format!(
                "{} is not valid JSON, so it has not been overwritten. Fix it by hand or \
                 delete it (`takt auth logout --all`) and sign in again.",
                self.path.display()
            )));
        }
        client_config::write_private_file(
            &self.path,
            &client_config::encode_config_object(&self.values),
        )
        .map_err(|err| ToolError::new(err.to_string()))
    }

    pub fn delete(&self) -> Result<()> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(ToolError::new(format!(
                "Could not remove {}: {err}",
                self.path.display()
            ))),
        }
    }
}

/// The precedence rule itself, split out from the environment read so it can be
/// tested without mutating process environment — which is both unsound across
/// threads and exactly the kind of test that passes alone and fails in a suite.
pub fn choose(
    env_value: Option<String>,
    env_key: &'static str,
    file_value: Option<String>,
) -> (Option<String>, Source) {
    match (env_value, file_value) {
        (Some(value), _) => (Some(value), Source::Environment(env_key)),
        (None, Some(value)) => (Some(value), Source::ConfigFile),
        (None, None) => (None, Source::Unset),
    }
}

fn non_empty_env(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// A leading `~` in a hand-edited path, which a person will write and which
/// nothing else in the stack would expand.
fn expand_tilde(value: &str) -> String {
    let Some(rest) = value.strip_prefix('~') else {
        return value.to_string();
    };
    if !rest.is_empty() && !rest.starts_with('/') {
        return value.to_string();
    }
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() => format!("{home}{rest}"),
        _ => value.to_string(),
    }
}

/// The default location of the app's day-log store, used when neither the
/// environment nor the config names one.
///
/// Pointing at the app's directory by default is deliberate and is the one
/// place the two are joined: reading the dailies and day log the app writes is
/// the whole reason those commands exist. It stays overridable, so a CLI-only
/// setup on a machine without the app is a `store_directory` away.
///
/// `Takt` when it exists, else the app's pre-rename `Priority` directory, so
/// the CLI keeps reading the right data across the gap between installing the
/// renamed app and first opening it.
pub fn default_store_directory() -> PathBuf {
    app_support_path(None)
}

/// `entry` inside the app's Application Support directory, preferring the
/// current directory name and falling back to an earlier one that has it.
///
/// Asked per entry rather than per directory, because the app can create its
/// new directory (for plugins, say) before it has copied the database into it.
pub fn app_support_path(entry: Option<&str>) -> PathBuf {
    let base = Path::new(&std::env::var("HOME").unwrap_or_default())
        .join("Library")
        .join("Application Support");
    first_existing(
        std::iter::once(APP_SUPPORT_DIRECTORY)
            .chain(LEGACY_APP_SUPPORT_DIRECTORIES.iter().copied())
            .map(|name| match entry {
                Some(entry) => base.join(name).join(entry),
                None => base.join(name),
            })
            .collect(),
    )
}

pub fn default_prefs_path(bundle_ids: &[&str]) -> PathBuf {
    let base = Path::new(&std::env::var("HOME").unwrap_or_default())
        .join("Library")
        .join("Preferences");
    first_existing(
        bundle_ids
            .iter()
            .map(|id| base.join(format!("{id}.plist")))
            .collect(),
    )
}
