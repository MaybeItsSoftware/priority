import Foundation
import TaktCore

// What Checkvist sends is read by the core (`core/src/checkvist.rs`), which is
// lenient about types and key names; `CheckvistModels+Core.swift` turns its
// rows into these. The synthesised `Codable` is for Takt's own files only —
// the offline store and the task cache — which these types wrote.

struct CheckvistNote: Codable, Identifiable, Sendable, Equatable {
  let id: Int?
  let content: String
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct CheckvistTask: Codable, Identifiable, Sendable, Equatable {
  let id: Int
  let content: String
  let status: Int
  let due: String?
  let position: Int?
  let parentId: Int?
  let level: Int?
  let notes: [CheckvistNote]?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level, notes
    case updatedAt = "updated_at"
  }

  init(
    id: Int,
    content: String,
    status: Int,
    due: String?,
    position: Int? = nil,
    parentId: Int? = nil,
    level: Int? = nil,
    notes: [CheckvistNote]? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.content = content
    self.status = status
    self.due = due
    self.position = position
    self.parentId = parentId
    self.level = level
    self.notes = notes
    self.updatedAt = updatedAt
  }

  /// Parsing lives in `TaktCore.DueDateParsing`, so every declaration of
  /// this model — including the re-declared one `TaktAppLogic` compiles —
  /// resolves a due string the same way.
  var dueDate: Date? { DueDateParsing.date(from: due) }

  var isOverdue: Bool {
    guard let resolvedDueDate = dueDate else { return false }
    return resolvedDueDate < Calendar.current.startOfDay(for: Date())
  }

  var isDueToday: Bool {
    guard let resolvedDueDate = dueDate else { return false }
    return Calendar.current.isDateInToday(resolvedDueDate)
  }

  var hasNotes: Bool {
    guard let notes else { return false }
    return notes.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}

struct CheckvistList: Codable, Identifiable, Sendable, Equatable {
  let id: Int
  let name: String
  let archived: Bool?
  let readOnly: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, archived
    case readOnly = "read_only"
  }
}
