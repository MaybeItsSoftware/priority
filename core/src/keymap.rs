//! The desktop workspace's command catalogue and the user keymap laid over it.
//!
//! The catalogue (`keymap/catalogue.rs`) is every command a key, a palette
//! row or a menu item can name: its id, title, group, default keys, the
//! surface it belongs to and whether it is a motion. The Mac reads it once at
//! launch into `WorkspaceCommandCatalog.defaults` and builds its own lookup
//! table from it (`WorkspaceKeyBindings`), so no key press crosses into the
//! core; the iPhone reads the same entries for its hardware-keyboard
//! shortcuts, and Android for its palette and key handling, each taking the
//! commands it can run.
//!
//! A keymap file is Zed's shape: an array of blocks, each with an optional
//! `context` naming a surface and a `bindings` object from key to command id,
//! `null` unbinding. [`keymap_parse`] reads one, reporting what it skips;
//! [`keymap_resolve`] lays the bindings over the catalogue. Neither is
//! all-or-nothing: an entry that cannot be understood is skipped and
//! reported, and the rest applies.
//!
//! Keys are spelled one way everywhere: modifiers in the order `cmd`, `ctrl`,
//! `option`, `shift`, then the key, joined by `+` (`cmd+shift+u`); a named
//! key is one of [`KEY_NAMES`]; a two-letter sequence (`gg`) is typed as two
//! plain letters. [`keymap_normalized_key`] turns whatever a person wrote
//! into that spelling, and [`keyboard_chord`] takes it apart again for a
//! toolkit's own key type.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::OnceLock;

use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

mod catalogue;

/// Where a command applies. A surface is what is in the main pane, except
/// `Sidebar` and `Inspector`, whose keys belong to a region.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, uniffi::Enum)]
pub enum CommandSurface {
    Anywhere,
    Today,
    Board,
    Outline,
    Matrix,
    Sidebar,
    Inspector,
    Timeline,
    Done,
    Conditions,
}

impl CommandSurface {
    pub const ALL: [CommandSurface; 10] = [
        CommandSurface::Anywhere,
        CommandSurface::Today,
        CommandSurface::Board,
        CommandSurface::Outline,
        CommandSurface::Matrix,
        CommandSurface::Sidebar,
        CommandSurface::Inspector,
        CommandSurface::Timeline,
        CommandSurface::Done,
        CommandSurface::Conditions,
    ];

    /// The name a keymap's `context` and the Swift enum's raw value use.
    pub fn name(self) -> &'static str {
        match self {
            CommandSurface::Anywhere => "anywhere",
            CommandSurface::Today => "today",
            CommandSurface::Board => "board",
            CommandSurface::Outline => "outline",
            CommandSurface::Matrix => "matrix",
            CommandSurface::Sidebar => "sidebar",
            CommandSurface::Inspector => "inspector",
            CommandSurface::Timeline => "timeline",
            CommandSurface::Done => "done",
            CommandSurface::Conditions => "conditions",
        }
    }
}

/// Keys a command answers to on one surface only.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SurfaceKeys {
    pub surface: CommandSurface,
    pub keys: Vec<String>,
}

/// One row of the catalogue.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandEntry {
    pub id: String,
    pub title: String,
    pub group: String,
    /// The keys it answers to on its own surface (everywhere, for `Anywhere`).
    pub keys: Vec<String>,
    /// Keys it answers to on one other surface as though it were that
    /// surface's own row, in surface order.
    pub surface_keys: Vec<SurfaceKeys>,
    pub surface: CommandSurface,
    /// A motion moves the cursor from where it is, so a palette lists it but
    /// cannot run it.
    pub motion: bool,
    pub note: Option<String>,
}

/// The catalogue's entries as written, before a keymap.
pub(crate) struct Spec {
    id: &'static str,
    title: &'static str,
    group: &'static str,
    keys: &'static [&'static str],
    surface_keys: Vec<(CommandSurface, &'static [&'static str])>,
    surface: CommandSurface,
    motion: bool,
    note: Option<&'static str>,
}

pub(crate) fn c(
    id: &'static str,
    title: &'static str,
    group: &'static str,
    keys: &'static [&'static str],
) -> Spec {
    Spec {
        id,
        title,
        group,
        keys,
        surface_keys: Vec::new(),
        surface: CommandSurface::Anywhere,
        motion: false,
        note: None,
    }
}

impl Spec {
    /// The surface the command belongs to.
    pub(crate) fn on(mut self, surface: CommandSurface) -> Self {
        self.surface = surface;
        self
    }

    /// Keys it answers to on `surface` alone.
    pub(crate) fn also(mut self, surface: CommandSurface, keys: &'static [&'static str]) -> Self {
        self.surface_keys.push((surface, keys));
        self
    }

    pub(crate) fn motion(mut self) -> Self {
        self.motion = true;
        self
    }

    pub(crate) fn note(mut self, note: &'static str) -> Self {
        self.note = Some(note);
        self
    }

    fn entry(&self) -> CommandEntry {
        let strings = |keys: &[&str]| keys.iter().map(|key| key.to_string()).collect();
        let mut surface_keys: Vec<SurfaceKeys> = self
            .surface_keys
            .iter()
            .map(|(surface, keys)| SurfaceKeys {
                surface: *surface,
                keys: strings(keys),
            })
            .collect();
        surface_keys.sort_by_key(|entry| entry.surface);
        CommandEntry {
            id: self.id.to_string(),
            title: self.title.to_string(),
            group: self.group.to_string(),
            keys: strings(self.keys),
            surface_keys,
            surface: self.surface,
            motion: self.motion,
            note: self.note.map(str::to_string),
        }
    }
}

fn catalogue() -> &'static [CommandEntry] {
    static CATALOGUE: OnceLock<Vec<CommandEntry>> = OnceLock::new();
    CATALOGUE.get_or_init(|| catalogue::specs().iter().map(Spec::entry).collect())
}

/// Every command, in catalogue order, with its shipped keys.
#[uniffi::export]
pub fn workspace_command_catalog() -> Vec<CommandEntry> {
    catalogue().to_vec()
}

/// Commands that act on which key ran them (the digit that sets a priority,
/// the arrow that picks a direction), so another key cannot stand in.
pub const READS_ITS_KEY: [&str; 13] = [
    "goCycleRegion",
    "planMatrixPlace",
    "listNewTaskDestination",
    "motionSelectEnds",
    "motionSelectPage",
    "motionSidebarSelect",
    "motionBoardColumn",
    "motionSetPriority",
    "motionDoneSelect",
    "motionTimelineSelect",
    "motionConditionsSelect",
    "motionInspectorEnds",
    "motionInspectorLeave",
];

/// The command ids that cannot be rebound; see [`READS_ITS_KEY`].
#[uniffi::export]
pub fn keymap_reads_its_key() -> Vec<String> {
    READS_ITS_KEY.iter().map(|id| id.to_string()).collect()
}

/// The keys spelled by name rather than by their character.
pub const KEY_NAMES: [&str; 27] = [
    "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "=", "comma", "delete", "down", "end",
    "enter", "escape", "f2", "home", "left", "pagedown", "pageup", "right", "space", "tab", "up",
];

/// Whether `key` is a two-key sequence: two plain letters (`gg`), or a minus
/// and a digit (`-2`, a priority behind the back, as `!-2` writes it).
pub fn is_sequence(key: &str) -> bool {
    if is_minus_digit(key) {
        return true;
    }
    let mut characters = key.chars();
    let both = |c: Option<char>| c.is_some_and(|c| c.is_alphabetic() && c.is_lowercase());
    both(characters.next())
        && both(characters.next())
        && characters.next().is_none()
        && !KEY_NAMES.contains(&key)
}

fn is_minus_digit(key: &str) -> bool {
    let bytes = key.as_bytes();
    bytes.len() == 2 && bytes[0] == b'-' && bytes[1].is_ascii_digit()
}

// MARK: - Issues

/// What went wrong with part of a keymap file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeymapIssueKind {
    /// Not JSON, or not an array of blocks. Nothing in the file applies.
    UnreadableFile,
    /// A block that is not an object with a `bindings` object.
    MalformedBlock,
    /// A `context` that names no surface.
    UnknownContext,
    /// A command id the catalogue does not have.
    UnknownCommand,
    /// A key no key press can be spelled as.
    MalformedKey,
    /// A command that reads which key ran it.
    NotRebindable,
    /// A command that belongs to one surface, bound in another's context.
    WrongSurface,
    /// One key bound to two commands on one surface. The later wins.
    Conflict,
}

/// An issue, said in a sentence someone editing the file can act on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapIssue {
    pub kind: KeymapIssueKind,
    pub message: String,
}

fn issue(kind: KeymapIssueKind, message: String) -> KeymapIssue {
    KeymapIssue { kind, message }
}

// MARK: - Reading the file

/// One binding a keymap file asks for. `command` is `None` to unbind.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapBinding {
    pub context: Option<CommandSurface>,
    pub key: String,
    pub command: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapParse {
    pub bindings: Vec<KeymapBinding>,
    pub issues: Vec<KeymapIssue>,
}

/// The surface a keymap `context` names, ignoring case and outer spaces.
#[uniffi::export]
pub fn keymap_surface_named(name: String) -> Option<CommandSurface> {
    let wanted = name.trim_matches(is_space).to_lowercase();
    CommandSurface::ALL
        .into_iter()
        .find(|surface| surface.name() == wanted)
}

fn surface_names() -> String {
    CommandSurface::ALL
        .iter()
        .map(|surface| surface.name())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Spaces, not line breaks: what Foundation's `.whitespaces` trims.
fn is_space(character: char) -> bool {
    character.is_whitespace()
        && !matches!(
            character,
            '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

/// A JSON value as the message names it.
fn describe(value: &Value) -> String {
    match value {
        Value::String(string) => format!("\"{string}\""),
        Value::Number(number) => number.to_string(),
        Value::Bool(flag) => if *flag { "1" } else { "0" }.to_string(),
        Value::Array(_) => "an array".to_string(),
        Value::Object(_) => "an object".to_string(),
        Value::Null => "nothing".to_string(),
    }
}

/// Reads a keymap file. An empty file is no bindings. Within a block, the
/// unbinds come before the binds, each in key order, so unbinding and
/// rebinding one key in a block does not depend on the order written.
#[uniffi::export]
pub fn keymap_parse(text: String) -> KeymapParse {
    let mut issues = Vec::new();
    let mut bindings = Vec::new();
    if text.trim().is_empty() {
        return KeymapParse { bindings, issues };
    }
    let json: Value = match serde_json::from_str(&text) {
        Ok(json) => json,
        Err(error) => {
            issues.push(issue(
                KeymapIssueKind::UnreadableFile,
                format!("keymap.json is not valid JSON: {error}"),
            ));
            return KeymapParse { bindings, issues };
        }
    };
    let Value::Array(blocks) = json else {
        issues.push(issue(
            KeymapIssueKind::UnreadableFile,
            "keymap.json should be an array of blocks, like [{\"bindings\": {…}}]".to_string(),
        ));
        return KeymapParse { bindings, issues };
    };
    let known: HashSet<&str> = catalogue().iter().map(|entry| entry.id.as_str()).collect();
    for (offset, element) in blocks.iter().enumerate() {
        let label = format!("Block {}", offset + 1);
        let Value::Object(block) = element else {
            issues.push(issue(
                KeymapIssueKind::MalformedBlock,
                format!("{label} is not an object; skipped"),
            ));
            continue;
        };
        let mut context = None;
        if let Some(raw) = block.get("context").filter(|raw| !raw.is_null()) {
            let surface = raw
                .as_str()
                .and_then(|name| keymap_surface_named(name.to_string()));
            let Some(surface) = surface else {
                let shown = match raw {
                    Value::String(string) => string.clone(),
                    other => describe(other),
                };
                issues.push(issue(
                    KeymapIssueKind::UnknownContext,
                    format!(
                        "{label}: context \"{shown}\" is not a surface — use one of {}; block skipped",
                        surface_names()
                    ),
                ));
                continue;
            };
            context = (surface != CommandSurface::Anywhere).then_some(surface);
        }
        let Some(Value::Object(entries)) = block.get("bindings") else {
            issues.push(issue(
                KeymapIssueKind::MalformedBlock,
                format!("{label} has no \"bindings\" object; skipped"),
            ));
            continue;
        };
        let mut unbinds = Vec::new();
        let mut binds = Vec::new();
        let sorted: BTreeMap<&String, &Value> = entries.iter().collect();
        for (raw_key, value) in sorted {
            let key = match normalized_key(raw_key, Some(&label)) {
                Ok(key) => key,
                Err(problem) => {
                    issues.push(problem);
                    continue;
                }
            };
            match value {
                Value::Null => unbinds.push(KeymapBinding {
                    context,
                    key,
                    command: None,
                }),
                Value::String(name) if known.contains(name.as_str()) => binds.push(KeymapBinding {
                    context,
                    key,
                    command: Some(name.clone()),
                }),
                other => issues.push(issue(
                    KeymapIssueKind::UnknownCommand,
                    format!(
                        "{label}: \"{raw_key}\" is bound to {}, which is not a command id; skipped",
                        describe(other)
                    ),
                )),
            }
        }
        bindings.extend(unbinds);
        bindings.extend(binds);
    }
    KeymapParse { bindings, issues }
}

// MARK: - Laying it over the catalogue

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapResolution {
    /// The commands passed, in their order, with the keys in force.
    pub commands: Vec<CommandEntry>,
    /// Keys taken away from a surface by a `null` in a block naming it: a
    /// surface's own rows still answer, but the key is no longer inherited
    /// from `Anywhere`.
    pub unbound: Vec<SurfaceKeys>,
    pub issues: Vec<KeymapIssue>,
}

/// Lays `bindings` over `defaults` (the catalogue, normally). A binding
/// without a context adds the key on the command's own surface; one with a
/// context adds it there, as one of that surface's own keys. Either takes the
/// key from whatever held it on that surface. `null` without a context
/// unbinds the key everywhere; with one, on that surface only.
#[uniffi::export]
pub fn keymap_resolve(
    bindings: Vec<KeymapBinding>,
    defaults: Vec<CommandEntry>,
) -> KeymapResolution {
    let mut keys: Vec<Vec<String>> = defaults.iter().map(|entry| entry.keys.clone()).collect();
    let mut surface_keys: Vec<BTreeMap<CommandSurface, Vec<String>>> = defaults
        .iter()
        .map(|entry| {
            entry
                .surface_keys
                .iter()
                .map(|entry| (entry.surface, entry.keys.clone()))
                .collect()
        })
        .collect();
    let mut unbound: BTreeMap<CommandSurface, Vec<String>> = BTreeMap::new();
    let mut issues = Vec::new();
    let mut index: HashMap<&str, usize> = HashMap::new();
    for (row, entry) in defaults.iter().enumerate() {
        index.entry(entry.id.as_str()).or_insert(row);
    }
    let mut given: HashMap<(CommandSurface, String), String> = HashMap::new();

    let release = |keys: &mut Vec<Vec<String>>,
                   surface_keys: &mut Vec<BTreeMap<CommandSurface, Vec<String>>>,
                   key: &str,
                   scope: CommandSurface| {
        for row in 0..defaults.len() {
            if defaults[row].surface == scope {
                keys[row].retain(|held| held != key);
            }
            if let Some(held) = surface_keys[row].get_mut(&scope) {
                held.retain(|held| held != key);
                if held.is_empty() {
                    surface_keys[row].remove(&scope);
                }
            }
        }
    };

    for binding in &bindings {
        let Some(id) = &binding.command else {
            if let Some(context) = binding.context {
                release(&mut keys, &mut surface_keys, &binding.key, context);
                let held = unbound.entry(context).or_default();
                if !held.contains(&binding.key) {
                    held.push(binding.key.clone());
                }
            } else {
                for row in 0..defaults.len() {
                    keys[row].retain(|held| held != &binding.key);
                    surface_keys[row].retain(|_, held| {
                        held.retain(|held| held != &binding.key);
                        !held.is_empty()
                    });
                }
            }
            continue;
        };
        let Some(&row) = index.get(id.as_str()) else {
            continue;
        };
        let command = &defaults[row];
        let placement = binding
            .context
            .map(|context| format!(" on {}", context.name()))
            .unwrap_or_default();
        if READS_ITS_KEY.contains(&id.as_str()) {
            issues.push(issue(
                KeymapIssueKind::NotRebindable,
                format!(
                    "{}{placement}: {id} acts on which key ran it, so it cannot be rebound; skipped",
                    binding.key
                ),
            ));
            continue;
        }
        if let Some(context) = binding.context.filter(|context| {
            command.surface != CommandSurface::Anywhere && command.surface != *context
        }) {
            issues.push(issue(
                KeymapIssueKind::WrongSurface,
                format!(
                    "{} on {}: {id} only runs on {}; skipped",
                    binding.key,
                    context.name(),
                    command.surface.name()
                ),
            ));
            continue;
        }
        let scope = binding.context.unwrap_or(command.surface);
        let slot = (scope, binding.key.clone());
        if let Some(earlier) = given.get(&slot).filter(|earlier| *earlier != id) {
            issues.push(issue(
                KeymapIssueKind::Conflict,
                format!(
                    "{} on {} is bound to both {earlier} and {id}; {id} wins",
                    binding.key,
                    scope.name()
                ),
            ));
        }
        given.insert(slot, id.clone());

        release(&mut keys, &mut surface_keys, &binding.key, scope);
        match binding.context {
            Some(context) if context != command.surface => {
                surface_keys[row]
                    .entry(context)
                    .or_default()
                    .push(binding.key.clone());
            }
            _ => keys[row].push(binding.key.clone()),
        }
    }

    let commands = defaults
        .iter()
        .enumerate()
        .map(|(row, entry)| CommandEntry {
            keys: keys[row].clone(),
            surface_keys: surface_keys[row]
                .iter()
                .map(|(surface, keys)| SurfaceKeys {
                    surface: *surface,
                    keys: keys.clone(),
                })
                .collect(),
            ..entry.clone()
        })
        .collect();
    KeymapResolution {
        commands,
        unbound: unbound
            .into_iter()
            .map(|(surface, keys)| SurfaceKeys { surface, keys })
            .collect(),
        issues,
    }
}

// MARK: - Spelling a key

/// `raw` in the catalogue's spelling, or why it cannot be a key.
#[uniffi::export]
pub fn keymap_normalized_key(raw: String) -> Result<String, KeymapKeyError> {
    normalized_key(&raw, None).map_err(|problem| KeymapKeyError::Malformed {
        reason: problem.message,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum KeymapKeyError {
    #[error("{reason}")]
    Malformed { reason: String },
}

fn normalized_key(raw: &str, label: Option<&str>) -> Result<String, KeymapIssue> {
    let prefix = label.map(|label| format!("{label}: ")).unwrap_or_default();
    let reject = |why: &str| {
        Err(issue(
            KeymapIssueKind::MalformedKey,
            format!("{prefix}\"{raw}\" {why}; skipped"),
        ))
    };
    let token = raw.trim_matches(is_space).to_lowercase();
    if token.is_empty() {
        return reject("is empty");
    }
    // Before splitting, where `-` would read as a separator.
    if is_minus_digit(&token) {
        return Ok(token);
    }
    let mut parts = split(&token);
    let raw_base = parts.pop().unwrap_or_default();
    if raw_base.is_empty() {
        return reject("has no key after its modifiers");
    }
    let mut modifiers = HashSet::new();
    for part in &parts {
        let Some(modifier) = modifier_alias(part) else {
            return reject(&format!(
                "has \"{part}\" where a modifier should be — use cmd, ctrl, option or shift"
            ));
        };
        modifiers.insert(modifier);
    }
    let base = base_alias(&raw_base).unwrap_or(&raw_base).to_string();
    let is_named = KEY_NAMES.contains(&base.as_str());
    let is_character = base.graphemes(true).count() == 1;
    let sequence = is_sequence(&base);
    if !(is_named || is_character || sequence) {
        return reject("is not a key Takt can recognise");
    }
    if sequence && !modifiers.is_empty() {
        return reject("puts a modifier on a sequence, which is typed as two plain keys");
    }
    if is_character
        && !is_named
        && modifiers.len() == 1
        && modifiers.contains("shift")
        && !base.chars().next().is_some_and(char::is_alphabetic)
    {
        return reject(
            "holds Shift on a character, which is already in the character — write the character itself, such as \"?\"",
        );
    }
    let mut spelled: Vec<&str> = ["cmd", "ctrl", "option", "shift"]
        .into_iter()
        .filter(|modifier| modifiers.contains(modifier))
        .collect();
    spelled.push(&base);
    Ok(spelled.join("+"))
}

fn split(token: &str) -> Vec<String> {
    if token.graphemes(true).count() == 1 {
        return vec![token.to_string()];
    }
    let separator = if token.contains('+') { '+' } else { '-' };
    let mut parts: Vec<String> = token.split(separator).map(str::to_string).collect();
    // A trailing separator is the key itself: `cmd++`, `ctrl--`.
    let count = parts.len();
    if count >= 2 && parts[count - 1].is_empty() && parts[count - 2].is_empty() {
        parts.truncate(count - 2);
        parts.push(separator.to_string());
    }
    parts
}

fn modifier_alias(part: &str) -> Option<&'static str> {
    Some(match part {
        "cmd" | "command" | "⌘" | "super" => "cmd",
        "ctrl" | "control" | "⌃" => "ctrl",
        "option" | "opt" | "alt" | "⌥" => "option",
        "shift" | "⇧" => "shift",
        _ => return None,
    })
}

fn base_alias(base: &str) -> Option<&'static str> {
    Some(match base {
        "return" => "enter",
        "esc" => "escape",
        "backspace" | "del" => "delete",
        "pgup" | "page_up" => "pageup",
        "pgdn" | "page_down" => "pagedown",
        "," => "comma",
        " " => "space",
        "↑" => "up",
        "↓" => "down",
        "←" => "left",
        "→" => "right",
        _ => return None,
    })
}

// MARK: - Taking a key apart

/// A key in the catalogue's spelling, taken apart for a toolkit's own key
/// type: its modifiers and the key itself (a character, or one of
/// [`KEY_NAMES`]).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyboardChord {
    pub cmd: bool,
    pub ctrl: bool,
    pub option: bool,
    pub shift: bool,
    pub key: String,
    /// No modifier at all on a key that types or edits text (a character,
    /// enter, tab, delete): a text field keeps it, so a hardware keyboard
    /// shortcut on a phone must not claim it. Bare arrows and space are fine.
    pub belongs_to_typing: bool,
}

/// `cmd+shift+z` taken apart; `None` for a two-letter sequence, which no
/// single key press is, or for a spelling that is not the catalogue's.
#[uniffi::export]
pub fn keyboard_chord(key: String) -> Option<KeyboardChord> {
    if is_sequence(&key) {
        return None;
    }
    let mut parts = split(&key);
    let base = parts.pop().filter(|base| !base.is_empty())?;
    let mut chord = KeyboardChord {
        cmd: false,
        ctrl: false,
        option: false,
        shift: false,
        key: base.clone(),
        belongs_to_typing: false,
    };
    for part in parts {
        match part.as_str() {
            "cmd" => chord.cmd = true,
            "ctrl" => chord.ctrl = true,
            "option" => chord.option = true,
            "shift" => chord.shift = true,
            _ => return None,
        }
    }
    let bare = !(chord.cmd || chord.ctrl || chord.option || chord.shift);
    chord.belongs_to_typing = bare
        && (base.graphemes(true).count() == 1
            || matches!(base.as_str(), "enter" | "tab" | "delete"));
    Some(chord)
}

#[cfg(test)]
mod tests;
