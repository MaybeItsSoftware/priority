import Foundation

/// Where a command applies.
///
/// A surface is what is in the main pane, not which pane holds the caret —
/// `sidebar` and `inspector` are the two exceptions, because their keys really
/// do belong to a region rather than to a view.
public enum WorkspaceCommandSurface: String, CaseIterable, Sendable {
  case anywhere, today, board, outline, matrix, sidebar, inspector
  case timeline, done

  public var title: String {
    switch self {
    case .anywhere: "Anywhere"
    case .today: "Today"
    case .board: "Board"
    case .outline: "Outline"
    case .matrix: "Matrix"
    case .sidebar: "Sidebar"
    case .inspector: "Inspector"
    case .timeline: "Timeline"
    case .done: "Done rail"
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
  /// Keys the row answers to on one surface only, as though it were one of
  /// that surface's own rows. How `⌘R` renames the list from a task pane while
  /// `F2` renames it only from the sidebar, where on a task pane it renames
  /// the task; and how a keymap block with a `context` binds a key.
  public let surfaceKeys: [WorkspaceCommandSurface: [String]]
  public let surface: WorkspaceCommandSurface
  public let kind: WorkspaceCommandKind
  public let note: String?

  public init(
    id: WorkspaceCommandID,
    title: String,
    group: String,
    keys: [String],
    surfaceKeys: [WorkspaceCommandSurface: [String]] = [:],
    surface: WorkspaceCommandSurface = .anywhere,
    kind: WorkspaceCommandKind = .action,
    note: String? = nil
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.keys = keys
    self.surfaceKeys = surfaceKeys
    self.surface = surface
    self.kind = kind
    self.note = note
  }

  /// Every key the row answers to somewhere: `keys`, then each surface's
  /// `surfaceKeys` in the order surfaces are declared, without repeats.
  public var allKeys: [String] {
    var seen: Set<String> = []
    let surfaceOnly = WorkspaceCommandSurface.allCases.flatMap { surfaceKeys[$0] ?? [] }
    return (keys + surfaceOnly).filter { seen.insert($0).inserted }
  }

  /// Display-ready alternatives — `["⌘K", "⇧⇧"]` — in the order listed.
  public var displayKeys: [String] {
    allKeys.map(ShortcutReference.display(token:)).filter { !$0.isEmpty }
  }

  /// A copy with different keys — what a keymap makes of a row.
  public func rebound(
    keys: [String],
    surfaceKeys: [WorkspaceCommandSurface: [String]]
  ) -> WorkspaceCommand {
    WorkspaceCommand(
      id: id, title: title, group: group, keys: keys, surfaceKeys: surfaceKeys,
      surface: surface, kind: kind, note: note)
  }

  /// Everything a query is matched against, so "quadrant" finds the matrix row
  /// whose title does not use the word.
  public var searchText: String {
    ([title, group, note ?? ""] + displayKeys).joined(separator: " ")
  }
}
