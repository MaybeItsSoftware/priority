//! What Takt writes into an AFFiNE document, how it rewrites its own half of
//! one it wrote before, and the checklist it reads ticks back out of.
//!
//! AFFiNE stores documents as CRDT blocks, not text: Markdown goes in through
//! an importer and comes back through an exporter, and anything the importer
//! has no block for is dropped. So the region Takt owns is delimited by a
//! heading, a real block that survives the round trip, rather than the HTML
//! comment markers a daily note in Obsidian uses.
//!
//! The checklist is `- [ ]` todo blocks, each linking its Checkvist
//! permalink: AFFiNE's exporter backslash-escapes every ASCII punctuation
//! character in a link label, so the text that comes back is never the text
//! that was sent, and the `#t<id>` fragment is what traces a tick back to a
//! task.
//!
//! Replaces Swift's `AFFiNEDocumentMarkdown` and `AFFiNEChecklistMarkdown`,
//! which keep their types and wrap this, one call per document. Text is split
//! and trimmed as Swift's `String` does (`swift_text`): a `\r\n` is one line
//! ending that does not split, and titles compare by canonical equivalence.

use crate::swift_text::{self, lines, trim, trim_newlines, trim_spaces};

/// The heading Takt owns in a day's document.
pub const DAY_HEADING: &str = "## Log";
/// The heading Takt owns in a list's checklist document.
pub const CHECKLIST_HEADING: &str = "## Tasks";
const NOTHING_OPEN: &str = "_Nothing open._";

/// A task as it is written into a checklist.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AffineChecklistTask {
    pub id: i64,
    pub title: String,
    pub permalink: Option<String>,
    pub depth: i64,
}

/// A todo line read back out of a checklist.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AffineChecklistItem {
    /// None for an item Takt did not write.
    pub task_id: Option<i64>,
    pub title: String,
    pub is_checked: bool,
    pub depth: i64,
    /// The line as read, so an item Takt does not own goes back unchanged.
    pub raw: String,
}

/// Everything a sync reads out of a checklist, in one pass.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct AffineChecklistRead {
    /// Every todo line in the section, in document order.
    pub items: Vec<AffineChecklistItem>,
    /// Lines in the section Takt did not write: hand-typed items and prose.
    pub unowned_lines: Vec<String>,
}

// -- Task documents -------------------------------------------------------------

/// A document title for a task, on one line: a newline would arrive in
/// AFFiNE as a title plus a stray paragraph.
#[uniffi::export]
pub fn affine_task_title(content: String) -> String {
    let collapsed = collapse_lines(&content);
    if collapsed.is_empty() {
        "Untitled task".to_string()
    } else {
        collapsed
    }
}

/// The body of a task's document, without the title AFFiNE carries
/// separately. `synced_at` is the caller's formatted stamp.
#[uniffi::export]
pub fn affine_task_document(
    permalink: Option<String>,
    task_id: i64,
    notes: Vec<String>,
    synced_at: String,
) -> String {
    let mut out: Vec<String> = Vec::new();
    match permalink.as_deref() {
        Some(link) if !trim(link).is_empty() => out.push(format!("[Open in Checkvist]({link})")),
        _ => out.push(format!("Task ID: {task_id}")),
    }
    out.push(String::new());
    out.push(format!("_Synced from Takt · {synced_at}_"));
    out.push(String::new());
    out.push("## Notes".to_string());
    out.push(String::new());

    let contents: Vec<&str> = notes
        .iter()
        .map(|note| trim(note))
        .filter(|note| !note.is_empty())
        .collect();
    if contents.is_empty() {
        out.push("_No notes_".to_string());
    } else {
        for content in contents {
            out.push(content.to_string());
            out.push(String::new());
        }
        out.pop();
    }
    out.join("\n")
}

// -- Merging a section into a document ------------------------------------------

/// Splices `section` into `existing`, replacing the block `heading` already
/// owns and appending one otherwise. The block ends at the next heading of
/// the same level or shallower, so a `###` Takt wrote goes with it and the
/// `##` the user wrote below survives.
#[uniffi::export]
pub fn affine_merged(section: String, heading: String, existing: String) -> String {
    merged(&section, &heading, &existing)
}

/// What is written under `heading`, heading line excluded, or None when the
/// document has no such heading: "the section is empty" and "there is no
/// section" mean different things to a caller deciding whether to create it.
#[uniffi::export]
pub fn affine_body_under(heading: String, markdown: String) -> Option<String> {
    body_under(&heading, &markdown)
}

fn merged(section: &str, heading: &str, existing: &str) -> String {
    let section = trim(section);
    let document = lines(existing);
    let Some((start, end)) = block_range(heading, &document) else {
        let existing = trim(existing);
        return if existing.is_empty() {
            format!("{section}\n")
        } else {
            format!("{existing}\n\n{section}\n")
        };
    };
    let mut out: Vec<&str> = document[..start].to_vec();
    out.extend(lines(section));
    if end < document.len() {
        out.push("");
        out.extend_from_slice(&document[end..]);
    }
    format!("{}\n", trim(&out.join("\n")))
}

fn body_under(heading: &str, markdown: &str) -> Option<String> {
    let document = lines(markdown);
    let (start, end) = block_range(heading, &document)?;
    Some(trim_newlines(&document[start + 1..end].join("\n")).to_string())
}

/// The lines a heading owns, as a half-open range: the heading, and
/// everything up to the next heading of the same level or shallower.
fn block_range(heading: &str, document: &[&str]) -> Option<(usize, usize)> {
    let level = heading_level(heading).unwrap_or(2);
    let wanted = trim_spaces(heading);
    let start = document
        .iter()
        .position(|line| swift_text::same(trim_spaces(line), wanted))?;
    let end = document[start + 1..]
        .iter()
        .position(|line| heading_level(line).is_some_and(|candidate| candidate <= level))
        .map_or(document.len(), |offset| start + 1 + offset);
    Some((start, end))
}

/// The `#` count of an ATX heading, or None for anything that is not one.
fn heading_level(line: &str) -> Option<usize> {
    let trimmed = trim_spaces(line);
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    trimmed[hashes..].starts_with(' ').then_some(hashes)
}

// -- Checklists -------------------------------------------------------------------

/// The checklist section. `carried_over` is lines found in the section that
/// Takt did not write: the section is Takt's to rewrite, but a note someone
/// typed into it is not Takt's to delete.
#[uniffi::export]
pub fn affine_checklist_section(
    tasks: Vec<AffineChecklistTask>,
    carried_over: Vec<String>,
    heading: String,
) -> String {
    section(&tasks, &carried_over, &heading)
}

/// The section's todo items and the lines Takt does not own, in one pass.
/// A document without the heading reads as nothing rather than everything.
#[uniffi::export]
pub fn affine_checklist_read(markdown: String, heading: String) -> AffineChecklistRead {
    read(&markdown, &heading)
}

/// Whether the items already say what Takt is about to write. Compared item
/// by item, because the text differs by escaping every time.
#[uniffi::export]
pub fn affine_checklist_matches(
    items: Vec<AffineChecklistItem>,
    tasks: Vec<AffineChecklistTask>,
) -> bool {
    matches(&items, &tasks)
}

/// The document with its checklist rewritten to `tasks`, keeping the lines
/// Takt does not own, or None when nothing was ticked (`ticked_any` false)
/// and the checklist already says the same: rewriting would churn the
/// document's history for no change anyone made.
#[uniffi::export]
pub fn affine_checklist_rewrite(
    existing: String,
    tasks: Vec<AffineChecklistTask>,
    heading: String,
    ticked_any: bool,
) -> Option<String> {
    let found = read(&existing, &heading);
    if !ticked_any && matches(&found.items, &tasks) {
        return None;
    }
    Some(merged(
        &section(&tasks, &found.unowned_lines, &heading),
        &heading,
        &existing,
    ))
}

/// The task id a Checkvist permalink ends with (`#t<id>`). Matching on that
/// rather than the host keeps a self-hosted or rewritten link working.
#[uniffi::export]
pub fn affine_task_id_in_permalink(permalink: String) -> Option<i64> {
    task_id_in_permalink(&permalink)
}

fn section(tasks: &[AffineChecklistTask], carried_over: &[String], heading: &str) -> String {
    let mut out = vec![heading.to_string(), String::new()];
    if tasks.is_empty() && carried_over.is_empty() {
        out.push(NOTHING_OPEN.to_string());
        return out.join("\n");
    }
    out.extend(tasks.iter().map(line_for));
    if !carried_over.is_empty() {
        if !tasks.is_empty() {
            out.push(String::new());
        }
        out.extend(carried_over.iter().cloned());
    }
    out.join("\n")
}

fn line_for(task: &AffineChecklistTask) -> String {
    let indent = "  ".repeat(usize::try_from(task.depth.max(0)).unwrap_or(0));
    let label = escaped_label(&task.title);
    match task.permalink.as_deref() {
        Some(link) if !trim(link).is_empty() => format!("{indent}- [ ] [{label}]({link})"),
        _ => format!("{indent}- [ ] {label}"),
    }
}

/// Only the three characters that would end the label early. Escaping more
/// would be undone by AFFiNE's own escaping on the way back.
fn escaped_label(raw: &str) -> String {
    let collapsed = collapse_lines(raw);
    if collapsed.is_empty() {
        return "(untitled)".to_string();
    }
    collapsed
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
}

/// Line breaks as spaces, then trimmed: `\r\n` first, so it becomes one space.
fn collapse_lines(text: &str) -> String {
    trim(&text.replace("\r\n", " ").replace(['\n', '\r'], " ")).to_string()
}

fn read(markdown: &str, heading: &str) -> AffineChecklistRead {
    let Some(body) = body_under(heading, markdown) else {
        return AffineChecklistRead::default();
    };
    let mut found = AffineChecklistRead::default();
    for line in lines(&body) {
        let item = item_from(line);
        let trimmed = trim_spaces(line);
        // The placeholder is Takt's, and putting it back beside real items
        // would be a lie.
        let owned = item.as_ref().is_some_and(|item| item.task_id.is_some());
        if !trimmed.is_empty() && trimmed != NOTHING_OPEN && !owned {
            found.unowned_lines.push(line.to_string());
        }
        found.items.extend(item);
    }
    found
}

fn matches(items: &[AffineChecklistItem], tasks: &[AffineChecklistTask]) -> bool {
    let owned: Vec<&AffineChecklistItem> =
        items.iter().filter(|item| item.task_id.is_some()).collect();
    owned.len() == tasks.len()
        && owned.iter().zip(tasks).all(|(item, task)| {
            item.task_id == Some(task.id)
                && !item.is_checked
                && item.depth == task.depth
                && swift_text::same(&normalised(&item.title), &normalised(&task.title))
        })
}

fn normalised(title: &str) -> String {
    trim(&unescaped(title)).to_string()
}

/// One checklist line, or None for a line that is not a todo item.
fn item_from(line: &str) -> Option<AffineChecklistItem> {
    let mut indent = 0;
    let mut rest = line;
    while let Some(first) = rest.chars().next().filter(|c| *c == ' ' || *c == '\t') {
        indent += if first == '\t' { 2 } else { 1 };
        rest = &rest[1..];
    }
    rest = rest.strip_prefix(['-', '*', '+'])?;
    rest = rest.strip_prefix(' ')?;
    rest = rest.strip_prefix('[')?;
    let is_checked = match rest.chars().next()? {
        ' ' => false,
        'x' | 'X' => true,
        _ => return None,
    };
    rest = rest[1..].strip_prefix(']')?;
    rest = rest.strip_prefix(' ').unwrap_or(rest);

    let content = trim_spaces(rest);
    let link = markdown_link(content);
    Some(AffineChecklistItem {
        task_id: link
            .as_ref()
            .and_then(|(_, destination)| task_id_in_permalink(destination)),
        title: unescaped(link.as_ref().map_or(content, |(label, _)| label.as_str())),
        is_checked,
        depth: indent / 2,
        raw: line.to_string(),
    })
}

/// A leading `[label](destination)`, honouring backslash escapes so a label
/// containing `]` does not end it early. The label keeps its escapes.
fn markdown_link(content: &str) -> Option<(String, String)> {
    let mut chars = content.strip_prefix('[')?.chars();
    let mut label = String::new();
    loop {
        match chars.next()? {
            '\\' => {
                label.push('\\');
                match chars.next() {
                    Some(next) => label.push(next),
                    // A trailing backslash with nothing after it is literal,
                    // and the label is unclosed.
                    None => return None,
                }
            }
            ']' => break,
            other => label.push(other),
        }
    }
    let rest = chars.as_str().strip_prefix('(')?;
    let close = rest.find(')')?;
    Some((label, rest[..close].to_string()))
}

fn task_id_in_permalink(permalink: &str) -> Option<i64> {
    let hash = permalink.rfind('#')?;
    let digits = permalink[hash + 1..].strip_prefix('t')?;
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// Drops one level of backslash escaping: AFFiNE's on the way out, or Takt's
/// on the way in. A trailing lone backslash is kept.
fn unescaped(raw: &str) -> String {
    let mut output = String::with_capacity(raw.len());
    let mut escaped = false;
    for character in raw.chars() {
        if escaped {
            output.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            output.push(character);
        }
    }
    if escaped {
        output.push('\\');
    }
    output
}

#[cfg(test)]
mod tests;
