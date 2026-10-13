import Foundation
import TaktRustCore

// The catalogue and the keymap are the Rust core's (`core/src/keymap.rs`);
// these convert between its records and the Mac's types, once per load.

extension WorkspaceCommandSurface {
  init(core surface: CommandSurface) {
    switch surface {
    case .anywhere: self = .anywhere
    case .today: self = .today
    case .board: self = .board
    case .outline: self = .outline
    case .matrix: self = .matrix
    case .sidebar: self = .sidebar
    case .inspector: self = .inspector
    case .timeline: self = .timeline
    case .done: self = .done
    case .conditions: self = .conditions
    }
  }

  var core: CommandSurface {
    switch self {
    case .anywhere: .anywhere
    case .today: .today
    case .board: .board
    case .outline: .outline
    case .matrix: .matrix
    case .sidebar: .sidebar
    case .inspector: .inspector
    case .timeline: .timeline
    case .done: .done
    case .conditions: .conditions
    }
  }
}

extension WorkspaceCommand {
  /// Nil for an id this build's `WorkspaceCommandID` lacks; a test holds the
  /// two to one another, so that never happens in a shipped build.
  init?(core entry: CommandEntry) {
    guard let id = WorkspaceCommandID(rawValue: entry.id) else { return nil }
    self.init(
      id: id, title: entry.title, group: entry.group, keys: entry.keys,
      surfaceKeys: Dictionary(
        entry.surfaceKeys.map { (WorkspaceCommandSurface(core: $0.surface), $0.keys) },
        uniquingKeysWith: { first, _ in first }),
      surface: WorkspaceCommandSurface(core: entry.surface),
      kind: entry.motion ? .motion : .action, note: entry.note)
  }

  var core: CommandEntry {
    CommandEntry(
      id: id.rawValue, title: title, group: group, keys: keys,
      surfaceKeys: WorkspaceCommandSurface.allCases.compactMap { surface in
        surfaceKeys[surface].map { SurfaceKeys(surface: surface.core, keys: $0) }
      },
      surface: surface.core, motion: kind == .motion, note: note)
  }
}

extension WorkspaceKeymapIssue.Kind {
  init(core kind: KeymapIssueKind) {
    switch kind {
    case .unreadableFile: self = .unreadableFile
    case .malformedBlock: self = .malformedBlock
    case .unknownContext: self = .unknownContext
    case .unknownCommand: self = .unknownCommand
    case .malformedKey: self = .malformedKey
    case .notRebindable: self = .notRebindable
    case .wrongSurface: self = .wrongSurface
    case .conflict: self = .conflict
    }
  }
}

extension WorkspaceKeymapIssue {
  init(core issue: KeymapIssue) {
    self.init(kind: Kind(core: issue.kind), message: issue.message)
  }
}
