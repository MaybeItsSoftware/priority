import Foundation

/// A tool call in words, for the transcript and the approval card.
///
/// The card is where the user decides, so it has to say what will happen in
/// terms they can check at a glance — "Add a task · Milk · to Groceries" — and
/// not as `{"list_id":"94EA6D2B-…","title":"Milk"}`. Ids are resolved to
/// titles through `name`, which the app answers from the workspace it has
/// loaded; an id it cannot resolve is shown as the id, so the card never
/// hides what it is about. The raw input stays available under a disclosure.
public struct AgentToolSummary: Equatable, Sendable {
  public struct Field: Equatable, Sendable {
    public let label: String
    public let value: String
    /// What it is now, for a change: the card shows it struck through beside
    /// `value`. Nil when it is not a change, or the value would not change.
    public let previous: String?

    public init(label: String, value: String, previous: String? = nil) {
      self.label = label
      self.value = value
      self.previous = previous
    }
  }

  /// A verb phrase: "Add a task", "Delete a task and everything under it".
  public let title: String
  public let fields: [Field]
  /// Deletes something. The card says so in the danger colour.
  public let isDestructive: Bool

  public init(title: String, fields: [Field], isDestructive: Bool) {
    self.title = title
    self.fields = fields
    self.isDestructive = isDestructive
  }

  /// The words for a write, as the approval card shows it.
  ///
  /// `current` answers what a key's value is now, already in words — the
  /// task's title for `title`, its list's name for `list_id` — for the keys
  /// a change would alter, so the card can show before and after. It is
  /// not asked about the key that names what is being changed (`task_id`).
  public static func describe(
    tool qualified: String,
    input: JSONValue,
    name: (String) -> String? = { _ in nil },
    current: (String) -> String? = { _ in nil },
    now: Date = .now,
    timeZone: TimeZone = .current
  ) -> AgentToolSummary {
    let tool = AgentToolPolicy.priorityToolName(qualified) ?? qualified
    var object = input.objectValue ?? [:]
    if tool == "agent_instructions_set" { object = instructionsAsTheyWouldBe(object, current: current) }
    let fields = orderedKeys(object).compactMap { key -> Field? in
      guard let value = object[key],
        let text = display(value, key: key, name: name, now: now, timeZone: timeZone)
      else {
        return nil
      }
      let previous = subjectKeys.contains(key) ? nil : current(key)
      return Field(label: label(for: key), value: text, previous: previous == text ? nil : previous)
    }
    return AgentToolSummary(
      title: titles[tool] ?? humanised(tool),
      fields: fields,
      isDestructive: destructiveTools.contains(tool))
  }

  /// An instructions edit shows the scope's whole text after it beside the
  /// whole text before (`current("text")`, nil when it has none): an append
  /// becomes the text it would make, and blank text, which clears the scope,
  /// reads "None" rather than vanishing from the card.
  private static func instructionsAsTheyWouldBe(
    _ object: [String: JSONValue], current: (String) -> String?
  ) -> [String: JSONValue] {
    var object = object
    let added = (object["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let before = current("text") ?? ""
    if object["mode"]?.stringValue == "append", !before.isEmpty {
      object["text"] = .string(added.isEmpty ? before : before + "\n\n" + added)
    } else {
      object["text"] = added.isEmpty ? .null : .string(added)
    }
    return object
  }

  /// One muted line for a read: `task_search · milk`. The tool's own name,
  /// because it is a log line rather than a question, and the argument that
  /// says what was looked at.
  public static func readLine(
    tool qualified: String,
    input: JSONValue,
    name: (String) -> String? = { _ in nil }
  ) -> String {
    let tool = AgentToolPolicy.priorityToolName(qualified) ?? qualified
    let object = input.objectValue ?? [:]
    for key in ["query", "content", "tag", "list_id", "parent_task_id", "task_id", "days", "id", "scope"] {
      if let value = object[key], let detail = display(value, key: key, name: name) {
        return "\(tool) · \(detail)"
      }
    }
    return tool
  }

  // MARK: - Words

  private static let titles: [String: String] = [
    "workspace_task_add": "Add a task",
    "workspace_task_update": "Change a task",
    "workspace_task_move": "Move a task",
    "workspace_task_to_list": "Turn a task into its own list",
    "workspace_task_delete": "Delete a task and everything under it",
    "workspace_folder_create": "Create a folder",
    "workspace_list_create": "Create a list",
    "workspace_list_move": "Move a list",
    "task_add": "Add a Checkvist task",
    "task_update": "Change a Checkvist task",
    "task_note_add": "Add a note to a Checkvist task",
    "task_move": "Reorder a Checkvist task",
    "task_reparent": "Move a Checkvist task",
    "project_move": "Move a Checkvist project to another list",
    "task_complete": "Complete a Checkvist task",
    "task_reopen": "Reopen a Checkvist task",
    "task_invalidate": "Mark a Checkvist task won't do",
    "task_delete": "Delete a Checkvist task",
    "list_create": "Create a Checkvist list",
    "task_matrix_set": "Place tasks on the matrix",
    "daily_add": "Create a daily",
    "daily_update": "Change a daily",
    "daily_tick": "Tick a daily",
    "agent_instructions_set": "Save standing instructions for the agent",
  ]

  private static let destructiveTools: Set<String> = ["workspace_task_delete", "task_delete"]

  /// Keys that say which thing a call is about rather than what it changes.
  private static let subjectKeys: Set<String> = ["task_id", "daily_id"]

  /// Keys in the order a person reads them: what, then where, then details.
  private static let keyOrder = [
    "task_id", "daily_id", "scope", "id", "title", "content", "name", "status", "done", "list_id",
    "source_list_id", "target_list_id", "parent_task_id", "folder_id", "parent_folder_id",
    "location", "position", "at_top", "kind", "pinned", "kanban_column", "due", "start",
    "priority", "estimate_minutes", "tags",
    "notes", "note", "external_links", "items", "text", "mode",
  ]

  private static let labels: [String: String] = [
    "task_id": "Task", "daily_id": "Daily", "title": "Title", "content": "Text",
    "name": "Name", "status": "Status", "done": "Done", "list_id": "List",
    "source_list_id": "From list", "target_list_id": "To list", "parent_task_id": "Under",
    "folder_id": "Folder", "parent_folder_id": "Inside", "location": "Where",
    "position": "Position", "at_top": "At the top", "kind": "Kind", "pinned": "Pinned",
    "kanban_column": "Column", "due": "Due", "tags": "Tags", "notes": "Notes", "note": "Note",
    "external_links": "Links", "items": "Items", "scope": "Scope", "id": "For",
    "text": "Instructions", "mode": "Mode", "start": "Start", "priority": "Priority",
    "estimate_minutes": "Estimate",
  ]

  /// Keys whose value is a day (`2026-10-17`) or a moment, shown as the app
  /// writes dates: "Fri 17 Oct", "Fri 17 Oct, 17:00".
  private static let dateKeys: Set<String> = ["due", "start", "follow_up_at"]

  /// The workspace's priorities, as the editor names them: 1 to 4, then
  /// -4 to -1 behind every task with none.
  private static let priorityNames = [
    1: "Urgent", 2: "High", 3: "Medium", 4: "Low", -4: "Later", -3: "Later still", -2: "Second to last", -1: "Last",
  ]

  /// A value the way the card shows it, for the app to put the task's
  /// current value in the same words: `priority` 1 is "1 (Urgent)", `due`
  /// "2026-10-17" is "Sat 17 Oct". Nil for a value not worth a row.
  public static func words(
    for key: String, value: JSONValue, now: Date = .now, timeZone: TimeZone = .current
  ) -> String? {
    display(value, key: key, name: { _ in nil }, now: now, timeZone: timeZone)
  }

  /// A moment as the tools take it, local and to the minute: what `words`
  /// reads back as a time rather than a day.
  public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
    formatter("yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: date)
  }

  /// Keys whose value is an id the app can put a name to.
  private static let idKeys: Set<String> = [
    "task_id", "list_id", "parent_task_id", "folder_id", "parent_folder_id", "source_list_id",
    "target_list_id", "id",
  ]

  private static func orderedKeys(_ object: [String: JSONValue]) -> [String] {
    let known = keyOrder.filter { object[$0] != nil }
    let rest = object.keys.filter { !keyOrder.contains($0) }.sorted()
    return known + rest
  }

  private static func label(for key: String) -> String {
    labels[key] ?? humanised(key)
  }

  /// `workspace_task_add` → "Workspace task add".
  private static func humanised(_ identifier: String) -> String {
    let words = identifier.split(separator: "_").joined(separator: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// A value as text, or `nil` for one not worth a row (an empty string).
  /// A present `null` is kept, because in an update it means "clear this".
  private static func display(
    _ value: JSONValue, key: String, name: (String) -> String?,
    now: Date = .now, timeZone: TimeZone = .current
  ) -> String? {
    if key == "priority", let level = value.intValue ?? (value == .null ? 0 : nil) {
      return priorityNames[level].map { "\(level) (\($0))" } ?? "None"
    }
    if key == "estimate_minutes", let minutes = value.intValue ?? (value == .null ? 0 : nil) {
      return minutes > 0 ? duration(minutes: minutes) : "None"
    }
    if dateKeys.contains(key), let text = value.stringValue,
      let date = dateWords(text, now: now, timeZone: timeZone)
    {
      return date
    }
    switch value {
    case .null:
      return key == "folder_id" || key == "parent_task_id" ? "Top level" : "None"
    case .bool(let flag):
      return flag ? "Yes" : "No"
    case .int(let number):
      return String(number)
    case .double(let number):
      return number.rounded() == number ? String(Int(number)) : String(number)
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if idKeys.contains(key), let resolved = name(trimmed) { return resolved }
      return trimmed
    case .array(let items):
      guard !items.isEmpty else { return "None" }
      if items.allSatisfy({ $0.stringValue != nil }) {
        return items.compactMap(\.stringValue).joined(separator: ", ")
      }
      return items.count == 1 ? "1 item" : "\(items.count) items"
    case .object:
      return value.jsonString()
    }
  }

  /// "45 min", "1 h 30 min", "2 h".
  private static func duration(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    switch (hours, rest) {
    case (0, _): return "\(rest) min"
    case (_, 0): return "\(hours) h"
    default: return "\(hours) h \(rest) min"
    }
  }

  /// A day or a moment in the card's words, or nil for text that is
  /// neither (Checkvist's `due` takes "friday" as it is).
  private static func dateWords(_ raw: String, now: Date, timeZone: TimeZone) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let sameYear = { (date: Date) in
      calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }
    if let day = formatter("yyyy-MM-dd", timeZone: timeZone).date(from: text), text.count == 10 {
      return formatter(sameYear(day) ? "EEE d MMM" : "EEE d MMM yyyy", timeZone: timeZone, words: true)
        .string(from: day)
    }
    let moment =
      ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]
      .lazy.compactMap { formatter($0, timeZone: timeZone).date(from: text) }.first
      ?? ISO8601DateFormatter().date(from: text)
    guard let moment else { return nil }
    return formatter(
      sameYear(moment) ? "EEE d MMM, HH:mm" : "EEE d MMM yyyy, HH:mm", timeZone: timeZone, words: true
    )
    .string(from: moment)
  }

  /// Fixed formats parse in POSIX; the card's words are British, as the
  /// system prompt's date is.
  private static func formatter(_ format: String, timeZone: TimeZone, words: Bool = false)
    -> DateFormatter
  {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: words ? "en_GB" : "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }
}
