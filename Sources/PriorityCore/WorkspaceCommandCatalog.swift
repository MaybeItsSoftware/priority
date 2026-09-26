import Foundation

/// Where a command applies.
///
/// A surface is what is in the main pane, not which pane holds the caret —
/// `sidebar` and `inspector` are the two exceptions, because their keys really
/// do belong to a region rather than to a view.
public enum WorkspaceCommandSurface: String, CaseIterable, Sendable {
  case anywhere, today, board, outline, matrix, sidebar, inspector
  case focus, focusRunning, timeline

  public var title: String {
    switch self {
    case .anywhere: "Anywhere"
    case .today: "Today"
    case .board: "Board"
    case .outline: "Outline"
    case .matrix: "Matrix"
    case .sidebar: "Sidebar"
    case .inspector: "Inspector"
    case .focus: "Focus ladder"
    case .focusRunning: "Running block"
    case .timeline: "Timeline"
    }
  }
}

/// Whether a row is something the palette can do for you.
///
/// The distinction is not decoration. A motion — `↓`, `J`, `Home` — means
/// "move the cursor from where it is", and a palette has already taken the
/// keyboard away from wherever that was, so running one from a list of rows
/// would either do nothing or do it somewhere you cannot see. Motions are
/// still listed, because the question "what can I press here" wants them;
/// they are just not selectable.
public enum WorkspaceCommandKind: Sendable, Equatable {
  case action
  case motion
}

public struct WorkspaceCommand: Identifiable, Sendable, Equatable {
  public let id: WorkspaceCommandID
  public let title: String
  public let group: String
  /// Raw binding tokens, rendered through `ShortcutReference.display(token:)`.
  /// Stored raw so the catalogue holds one spelling of a key and every reader
  /// — palette, reference sheet, hint bar — prints it the same way.
  public let keys: [String]
  public let surface: WorkspaceCommandSurface
  public let kind: WorkspaceCommandKind
  public let note: String?

  public init(
    id: WorkspaceCommandID,
    title: String,
    group: String,
    keys: [String],
    surface: WorkspaceCommandSurface = .anywhere,
    kind: WorkspaceCommandKind = .action,
    note: String? = nil
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.keys = keys
    self.surface = surface
    self.kind = kind
    self.note = note
  }

  /// Display-ready alternatives — `["⌘K", "⇧⇧"]` — in the order listed.
  public var displayKeys: [String] {
    keys.map(ShortcutReference.display(token:)).filter { !$0.isEmpty }
  }

  /// Everything a query is matched against, so "quadrant" finds the matrix row
  /// whose title does not use the word.
  public var searchText: String {
    ([title, group, note ?? ""] + displayKeys).joined(separator: " ")
  }
}
