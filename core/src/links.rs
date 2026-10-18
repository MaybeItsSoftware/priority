//! A task's links: Google Drive files and folders, Obsidian notes and
//! folders, and any other web address. See docs/links.md.
//!
//! The addresses are `task_metadata.externalLinksJSON`, the list every client
//! already reads, opens and edits; nothing here changes what that column
//! means. What a link *is* beyond its address — the file's name and type, as
//! the picker knew them — is `linkDetailsJSON` (`v31_link_details`), an
//! object keyed by address. A client that predates it drops the column and
//! still has every link, only without the names.
//!
//! Everything a client draws for a link comes from [`link_describe`]: the
//! kind, the title, a line under it and an icon hint, read from the address
//! and whatever details were stored. Clients open the address as it is.

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};

use crate::CoreError;
use crate::tasks::normalized_strings;
use crate::time::{decode_strings, stored, swift_json, swift_json_strings};

/// Where a link points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkKind {
    /// A Google Drive file or folder, a Doc, Sheet, Slides or Form.
    Drive,
    /// A note or folder in an Obsidian vault (`obsidian://`).
    Obsidian,
    /// Anything else with an address.
    Web,
}

/// A link as a client draws it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskLink {
    /// The address, as stored and as opened.
    pub url: String,
    pub kind: LinkKind,
    /// The stored name when there is one, else one read from the address:
    /// a note's file name, a folder's last component, "Google Sheet", a host.
    pub title: String,
    /// What it is and where: "Google Sheet", "Life · Projects", a host.
    pub subtitle: String,
    /// One of `doc`, `sheet`, `slides`, `form`, `pdf`, `image`, `file`,
    /// `folder`, `note`, `web`: each client maps it to its own symbol.
    pub icon: String,
    pub mime_type: Option<String>,
    pub is_folder: bool,
}

/// What `linkDetailsJSON` holds for one address.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct LinkDetails {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(rename = "mimeType", default, skip_serializing_if = "Option::is_none")]
    mime_type: Option<String>,
}

const GOOGLE_APPS: &str = "application/vnd.google-apps.";

/// Describes `url` for drawing, with the name and type the picker stored
/// when it made the link, if any.
#[uniffi::export]
pub fn link_describe(url: String, title: Option<String>, mime_type: Option<String>) -> TaskLink {
    describe(&url, title.as_deref(), mime_type.as_deref())
}

/// The address in `text` if the whole of it, trimmed, is one a task can
/// link to: `http`, `https` or `obsidian`, with something after the scheme
/// and no spaces. What pasting into an add field or a link field accepts.
#[uniffi::export]
pub fn link_from_text(text: String) -> Option<String> {
    parse_link(text.trim()).map(str::to_string)
}

/// The address that opens `path` (relative to the vault, with or without
/// `.md`) in the Obsidian vault named `vault`. A folder opens as a search
/// scoped to it, the one way Obsidian's URI scheme can show a folder.
#[uniffi::export]
pub fn obsidian_link_url(vault: String, path: String, is_folder: bool) -> String {
    let path = path.trim_matches('/');
    if is_folder {
        format!(
            "obsidian://search?vault={}&query={}",
            encode(&vault),
            encode(&format!("path:\"{path}\""))
        )
    } else {
        format!(
            "obsidian://open?vault={}&file={}",
            encode(&vault),
            encode(path)
        )
    }
}

pub(crate) fn parse_link(word: &str) -> Option<&str> {
    let lower = word.to_ascii_lowercase();
    let rest = ["https://", "http://", "obsidian://"]
        .iter()
        .find_map(|scheme| lower.strip_prefix(scheme))?;
    if rest.is_empty() || word.chars().any(char::is_whitespace) {
        return None;
    }
    Some(word)
}

fn describe(url: &str, title: Option<&str>, mime_type: Option<&str>) -> TaskLink {
    let named = title.map(str::trim).filter(|t| !t.is_empty());
    let mime = mime_type
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .map(str::to_string);
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("obsidian://") {
        return describe_obsidian(url, named, mime);
    }
    let host = host(url);
    if host == "docs.google.com" || host == "drive.google.com" {
        return describe_drive(url, &host, named, mime);
    }
    let shown_host = host.strip_prefix("www.").unwrap_or(&host).to_string();
    TaskLink {
        url: url.to_string(),
        kind: LinkKind::Web,
        title: named
            .map(str::to_string)
            .unwrap_or_else(|| web_title(url, &shown_host)),
        subtitle: shown_host,
        icon: icon_for_mime(mime.as_deref()).unwrap_or("web").into(),
        mime_type: mime,
        is_folder: false,
    }
}

fn describe_drive(url: &str, host: &str, named: Option<&str>, mime: Option<String>) -> TaskLink {
    let path = path(url);
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    // Read from the address first, then let a stored type sharpen it: a file
    // link to a PDF says only `file/d/…`.
    let from_address = if host == "docs.google.com" {
        match segments.first().copied() {
            Some("document") => Some("document"),
            Some("spreadsheets") => Some("spreadsheet"),
            Some("presentation") => Some("presentation"),
            Some("forms") => Some("form"),
            _ => None,
        }
    } else if segments.contains(&"folders") {
        Some("folder")
    } else {
        None
    };
    let google_type = mime
        .as_deref()
        .and_then(|m| m.strip_prefix(GOOGLE_APPS))
        .or(from_address);
    let (icon, kind_name) = match google_type {
        Some("document") => ("doc", "Google Doc"),
        Some("spreadsheet") => ("sheet", "Google Sheet"),
        Some("presentation") => ("slides", "Google Slides"),
        Some("form") => ("form", "Google Form"),
        Some("folder") => ("folder", "Drive folder"),
        _ => match icon_for_mime(mime.as_deref()) {
            Some("pdf") => ("pdf", "PDF in Drive"),
            Some("image") => ("image", "Image in Drive"),
            _ => ("file", "Drive file"),
        },
    };
    TaskLink {
        url: url.to_string(),
        kind: LinkKind::Drive,
        title: named.unwrap_or(kind_name).to_string(),
        subtitle: if named.is_some() {
            kind_name.to_string()
        } else {
            "Google Drive".to_string()
        },
        icon: icon.into(),
        mime_type: mime,
        is_folder: icon == "folder",
    }
}

fn describe_obsidian(url: &str, named: Option<&str>, mime: Option<String>) -> TaskLink {
    let action = url["obsidian://".len()..]
        .split(['?', '/'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let query = query_pairs(url);
    let value = |key: &str| {
        query
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.clone())
    };
    let vault = value("vault").unwrap_or_default();
    let (path, is_folder) = match action.as_str() {
        "search" => {
            let query = value("query").unwrap_or_default();
            match query
                .strip_prefix("path:")
                .map(|p| p.trim_matches('"').to_string())
            {
                Some(folder) => (folder, true),
                None => (query, false),
            }
        }
        _ => (
            value("file").or_else(|| value("path")).unwrap_or_default(),
            false,
        ),
    };
    let path = path.trim_matches('/');
    let mut components: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let last = components.pop().unwrap_or("");
    let shown = if is_folder {
        last.to_string()
    } else {
        last.strip_suffix(".md").unwrap_or(last).to_string()
    };
    let title = named
        .map(str::to_string)
        .or_else(|| (!shown.is_empty()).then(|| shown.clone()))
        .unwrap_or_else(|| {
            if vault.is_empty() {
                "Obsidian".into()
            } else {
                vault.clone()
            }
        });
    let place: Vec<&str> = std::iter::once(vault.as_str())
        .filter(|v| !v.is_empty())
        .chain(components.iter().copied())
        .collect();
    TaskLink {
        url: url.to_string(),
        kind: LinkKind::Obsidian,
        title,
        subtitle: if place.is_empty() {
            "Obsidian".into()
        } else {
            place.join(" · ")
        },
        icon: if is_folder { "folder" } else { "note" }.into(),
        mime_type: mime,
        is_folder,
    }
}

fn icon_for_mime(mime: Option<&str>) -> Option<&'static str> {
    let mime = mime?;
    if mime == "application/pdf" {
        Some("pdf")
    } else if mime.starts_with("image/") {
        Some("image")
    } else {
        None
    }
}

/// A web link's title: the last path component that reads as a name, else
/// the host.
fn web_title(url: &str, host: &str) -> String {
    let last = path(url)
        .split('/')
        .rev()
        .find(|s| !s.is_empty())
        .map(decode)
        .unwrap_or_default();
    if last.is_empty() || last.len() > 60 {
        host.to_string()
    } else {
        last
    }
}

fn after_scheme(url: &str) -> &str {
    url.split_once("://").map(|(_, rest)| rest).unwrap_or(url)
}

fn host(url: &str) -> String {
    let rest = after_scheme(url);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    host.split(':').next().unwrap_or("").to_ascii_lowercase()
}

fn path(url: &str) -> &str {
    let rest = after_scheme(url);
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    rest.find('/').map(|i| &rest[i..]).unwrap_or("")
}

fn query_pairs(url: &str) -> Vec<(String, String)> {
    let Some((_, query)) = url.split_once('?') else {
        return Vec::new();
    };
    let query = query.split('#').next().unwrap_or("");
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (decode(key), decode(value))
        })
        .collect()
}

/// Percent-decoding, with `+` left alone: Obsidian writes spaces as `%20`.
fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push((high * 16 + low) as u8);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Percent-encoding of everything but the unreserved characters.
fn encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

// MARK: - The workspace

/// A metadata row's addresses and what is known about them.
type StoredLinks = (Vec<String>, BTreeMap<String, LinkDetails>);

fn read_row(connection: &Connection, task_id: &str) -> Result<Option<StoredLinks>, CoreError> {
    let row = connection
        .query_row(
            "SELECT externalLinksJSON, linkDetailsJSON FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()?;
    Ok(row.map(|(links, details)| (decode_strings(&links), decode_details(details.as_deref()))))
}

fn decode_details(text: Option<&str>) -> BTreeMap<String, LinkDetails> {
    text.and_then(|t| serde_json::from_str(t).ok())
        .unwrap_or_default()
}

fn encode_details(details: &BTreeMap<String, LinkDetails>) -> Option<String> {
    if details.is_empty() {
        return None;
    }
    let value = serde_json::to_value(details).unwrap_or_default();
    Some(swift_json(&value))
}

/// The task's links, in the order they were added.
pub fn task_links(connection: &Connection, task_id: &str) -> Result<Vec<TaskLink>, CoreError> {
    let Some((links, details)) = read_row(connection, task_id)? else {
        return Ok(Vec::new());
    };
    Ok(links
        .iter()
        .map(|url| {
            let known = details.get(url).cloned().unwrap_or_default();
            describe(url, known.title.as_deref(), known.mime_type.as_deref())
        })
        .collect())
}

/// Every task with at least one link: what a client marks on its rows.
pub fn linked_task_ids(connection: &Connection) -> Result<Vec<String>, CoreError> {
    let mut statement = connection.prepare(
        "SELECT taskId FROM task_metadata
         WHERE externalLinksJSON IS NOT NULL AND externalLinksJSON NOT IN ('', '[]')",
    )?;
    let ids = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ids)
}

/// Adds `url` to the task's links, or renames it when it is already there.
/// Returns whether the address is new. A blank address is refused as a
/// missing task would be: there is nothing to add.
pub fn add_link(
    transaction: &Transaction,
    task_id: &str,
    url: &str,
    title: Option<&str>,
    mime_type: Option<&str>,
    now_ms: i64,
) -> Result<bool, CoreError> {
    ensure_task(transaction, task_id)?;
    let url = url.trim();
    if url.is_empty() {
        return Ok(false);
    }
    let (mut links, mut details) = read_row(transaction, task_id)?.unwrap_or_default();
    let existing = links.iter().find(|l| l.eq_ignore_ascii_case(url)).cloned();
    let is_new = existing.is_none();
    let key = existing.unwrap_or_else(|| url.to_string());
    if is_new {
        links.push(key.clone());
    }
    let title = title.map(str::trim).filter(|t| !t.is_empty());
    let mime = mime_type.map(str::trim).filter(|m| !m.is_empty());
    if title.is_some() || mime.is_some() {
        let entry = details.entry(key).or_default();
        if let Some(title) = title {
            entry.title = Some(title.to_string());
        }
        if let Some(mime) = mime {
            entry.mime_type = Some(mime.to_string());
        }
    }
    write(transaction, task_id, &links, details, now_ms)?;
    Ok(is_new)
}

/// Takes `url` off the task's links. Returns whether it was there.
pub fn remove_link(
    transaction: &Transaction,
    task_id: &str,
    url: &str,
    now_ms: i64,
) -> Result<bool, CoreError> {
    ensure_task(transaction, task_id)?;
    let Some((mut links, details)) = read_row(transaction, task_id)? else {
        return Ok(false);
    };
    let before = links.len();
    links.retain(|l| !l.eq_ignore_ascii_case(url.trim()));
    if links.len() == before {
        return Ok(false);
    }
    write(transaction, task_id, &links, details, now_ms)?;
    Ok(true)
}

fn ensure_task(connection: &Connection, task_id: &str) -> Result<(), CoreError> {
    let exists: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)",
        [task_id],
        |row| row.get(0),
    )?;
    if exists {
        Ok(())
    } else {
        Err(CoreError::MissingTask {
            id: task_id.to_string(),
        })
    }
}

fn write(
    transaction: &Transaction,
    task_id: &str,
    links: &[String],
    mut details: BTreeMap<String, LinkDetails>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let links = normalized_strings(links);
    // Details outlive their link only until the next write: an address taken
    // off in the editor's text field leaves its name behind until then.
    details.retain(|url, _| links.iter().any(|l| l == url));
    transaction.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, linkDetailsJSON, updatedAt)
         VALUES (?1, '[]', ?2, ?3, ?4)
         ON CONFLICT(taskId) DO UPDATE SET
           externalLinksJSON = excluded.externalLinksJSON,
           linkDetailsJSON = excluded.linkDetailsJSON,
           updatedAt = excluded.updatedAt",
        params![
            task_id,
            swift_json_strings(&links),
            encode_details(&details),
            stored(now_ms)
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests;
