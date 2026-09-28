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

    public init(label: String, value: String) {
      self.label = label
      self.value = value
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
  public static func describe(
    tool qualified: String,
    input: JSONValue,
    name: (String) -> String? = { _ in nil }
  ) -> AgentToolSummary {
    let tool = AgentToolPolicy.priorityToolName(qualified) ?? qualified
    let object = input.objectValue ?? [:]
    let fields = orderedKeys(object).compactMap { key -> Field? in
      guard let value = object[key], let text = display(value, key: key, name: name) else {
        return nil
      }
      return Field(label: label(for: key), value: text)
    }
    return AgentToolSummary(
      title: titles[tool] ?? humanised(tool),
      fields: fields,
      isDestructive: destructiveTools.contains(tool))
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
    for key in ["query", "content", "tag", "list_id", "parent_task_id", "task_id", "days"] {
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
  ]

  private static let destructiveTools: Set<String> = ["workspace_task_delete", "task_delete"]

  /// Keys in the order a person reads them: what, then where, then details.
  private static let keyOrder = [
    "task_id", "daily_id", "title", "content", "name", "status", "done", "list_id",
    "source_list_id", "target_list_id", "parent_task_id", "folder_id", "parent_folder_id",
    "location", "position", "at_top", "kind", "pinned", "kanban_column", "due", "tags",
    "notes", "note", "external_links", "items",
  ]

  private static let labels: [String: String] = [
    "task_id": "Task", "daily_id": "Daily", "title": "Title", "content": "Text",
    "name": "Name", "status": "Status", "done": "Done", "list_id": "List",
    "source_list_id": "From list", "target_list_id": "To list", "parent_task_id": "Under",
    "folder_id": "Folder", "parent_folder_id": "Inside", "location": "Where",
    "position": "Position", "at_top": "At the top", "kind": "Kind", "pinned": "Pinned",
    "kanban_column": "Column", "due": "Due", "tags": "Tags", "notes": "Notes", "note": "Note",
    "external_links": "Links", "items": "Items",
  ]

  /// Keys whose value is an id the app can put a name to.
  private static let idKeys: Set<String> = [
    "task_id", "list_id", "parent_task_id", "folder_id", "parent_folder_id", "source_list_id",
    "target_list_id",
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
    _ value: JSONValue, key: String, name: (String) -> String?
  ) -> String? {
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
}
