import Foundation

// The inspector's keyboard, as vim has it: a row cursor in normal mode, and
// a caret only once you ask to edit.
//
// The inspector used to walk its rows by handing each one the keyboard. That
// was fine for a button and a trap for a text field: ↓ put the caret in the
// notes, the notes kept ↓ for their own lines, and the walk stopped there for
// good. Now the cursor stands on a row without giving it the keyboard, so a
// field is only highlighted until Return, `i` or `e` opens it, and Esc (or
// Return in a one-line field) hands the keyboard back to the cursor.
//
// This is the state machine on its own. The inspector view feeds it the rows
// it drew and the keys it was sent, and does what the effects say.

/// What sort of row an inspector stop is, which decides what the keys do on it.
public enum InspectorStopKind: Equatable, Sendable {
  /// A button, switch, menu or date: Return presses it.
  case control
  /// A picker: Return opens it, and ← and → step its value.
  case adjustable
  /// A one-line text field: Return commits, Esc puts back what it had.
  case field
  /// The notes and the links: ↑ and ↓ move the caret, Esc commits.
  case multilineField

  /// Whether the row is typed into, and so must not hold the keyboard
  /// unless it is being edited.
  public var isText: Bool { self == .field || self == .multilineField }
}

/// One stop, as the inspector drew it: its name and its kind.
public struct InspectorStopInfo: Equatable, Sendable {
  public let id: String
  public let kind: InspectorStopKind

  public init(_ id: String, kind: InspectorStopKind) {
    self.id = id
    self.kind = kind
  }
}

/// Whether the keyboard is on the cursor or in a field.
public enum InspectorMode: Equatable, Sendable {
  case normal, editing
}

/// What the view has to do beyond moving the keyboard to `keyboardStop`.
public enum InspectorEffect: Equatable, Sendable {
  /// Press the control: a button's action, a switch's flip, a menu's opening.
  case press(String)
  /// Empty the field, or take the row's value away (a priority back to none,
  /// a switch off).
  case clearValue(String)
  /// Step a picker's value.
  case adjust(String, by: Int)
  /// Put back what the field had when editing began.
  case revert(String)
  /// Hand the keyboard back to the tasks.
  case leave
}

/// What a key typed inside an inspector field means, before the field sees it.
public enum InspectorEditingKey: Equatable, Sendable {
  /// Stop editing and keep the text. `passKey` lets the field have the key
  /// too, so a one-line field's own Return (saving the title, say) still runs.
  case commit(passKey: Bool)
  /// Stop editing and put the text back.
  case cancel
  /// Keep the text and edit the next or previous row.
  case tab(forward: Bool)
  /// Keep the text and move the cursor, in normal mode.
  case step(Int)

  /// The meaning of `key` (spelled as the catalogue spells keys) in a field
  /// of the inspector, or `nil` when the field keeps it.
  ///
  /// In a one-line field ↑ and ↓ have no line to move to, so they leave it,
  /// as they always have. In the notes they are the notes', and Esc is the
  /// only way out that a multi-line field cannot want for itself.
  public static func meaning(of key: String, multiline: Bool) -> InspectorEditingKey? {
    switch key {
    case "escape": multiline ? .commit(passKey: false) : .cancel
    case "cmd+enter": .commit(passKey: false)
    case "enter": multiline ? nil : .commit(passKey: true)
    case "tab": .tab(forward: true)
    case "shift+tab": .tab(forward: false)
    case "down": multiline ? nil : .step(1)
    case "up": multiline ? nil : .step(-1)
    default: nil
    }
  }
}

/// The inspector's cursor: which row it is on, and whether that row is
/// being edited.
public struct InspectorCursor: Equatable, Sendable {
  public private(set) var stops: [InspectorStopInfo]
  public private(set) var current: String?
  public private(set) var mode: InspectorMode = .normal

  public init(stops: [InspectorStopInfo] = [], current: String? = nil) {
    self.stops = stops
    self.current = current.flatMap { id in stops.contains { $0.id == id } ? id : nil }
  }

  public var isEditing: Bool { mode == .editing }

  public var currentKind: InspectorStopKind? {
    current.flatMap { id in stops.first { $0.id == id }?.kind }
  }

  /// The stop that should hold the keyboard: the field being edited, or the
  /// control under the cursor, so Space and a menu's arrows work on it as
  /// they would anywhere. A text row under the cursor in normal mode holds
  /// nothing — the inspector itself has the keyboard — which is the whole
  /// point: standing on the notes does not put the caret in them.
  public var keyboardStop: String? {
    guard let current, let kind = currentKind else { return nil }
    if mode == .editing { return current }
    return kind.isText ? nil : current
  }

  // MARK: The rows

  /// The rows as drawn now. A cursor whose row has gone moves to a row of the
  /// same family nearest where it was — the due date's × takes the date away
  /// and leaves "Add date", which is where the cursor should be — or failing
  /// that to whatever is now at its place.
  public mutating func updateStops(_ new: [InspectorStopInfo]) {
    let old = stops
    stops = new
    guard let current else { return }
    if let kind = currentKind {
      if mode == .editing && !kind.isText { mode = .normal }
      return
    }
    mode = .normal
    guard !new.isEmpty else {
      self.current = nil
      return
    }
    let place = old.firstIndex { $0.id == current } ?? 0
    let family = Self.family(of: current)
    let relatives = new.indices.filter { Self.family(of: new[$0].id) == family }
    if let nearest = relatives.min(by: { abs($0 - place) < abs($1 - place) }) {
      self.current = new[nearest].id
    } else {
      self.current = new[min(place, new.count - 1)].id
    }
  }

  /// Forgets the cursor: another task, or the inspector given up.
  public mutating func reset() {
    current = nil
    mode = .normal
  }

  /// "due" for "due.date" and "due.clear", "condition" for "condition.0.or".
  static func family(of id: String) -> Substring {
    id.split(separator: ".", maxSplits: 1).first ?? Substring(id)
  }

  // MARK: Normal mode

  /// `j`/`k`, `↓`/`↑`: one row on or back. The ends stop rather than wrap —
  /// falling off the foot of a form onto its title is not a thing anyone
  /// means. With no cursor yet, down starts at the top and up at the foot.
  public mutating func step(by offset: Int) {
    guard !stops.isEmpty else { return }
    mode = .normal
    let index = current.flatMap { id in stops.firstIndex { $0.id == id } }
    let next = index.map { $0 + offset } ?? (offset > 0 ? 0 : stops.count - 1)
    current = stops[min(max(next, 0), stops.count - 1)].id
  }

  /// `gg` and `Home`.
  public mutating func moveToFirst() {
    mode = .normal
    current = stops.first?.id
  }

  /// `G` and `End`.
  public mutating func moveToLast() {
    mode = .normal
    current = stops.last?.id
  }

  /// Puts the cursor on a row without editing it.
  public mutating func move(to id: String) {
    guard stops.contains(where: { $0.id == id }) else { return }
    mode = .normal
    current = id
  }

  /// Return, `i`, `e`: a text row opens for typing; anything else is pressed.
  /// With no cursor it starts on the first row.
  @discardableResult
  public mutating func activate() -> InspectorEffect? {
    if current == nil { moveToFirst() }
    guard let current, let kind = currentKind else { return nil }
    if kind.isText {
      mode = .editing
      return nil
    }
    return .press(current)
  }

  /// Opens the row for typing if it is a text row; otherwise just stands on it.
  public mutating func edit(_ id: String) {
    move(to: id)
    if currentKind?.isText == true { mode = .editing }
  }

  /// `x` and `Delete`: takes the row's value away. A value with its own ×
  /// beside it is cleared by pressing that, so the clearing is the one the
  /// mouse does; anything else the view clears itself.
  public func clear() -> InspectorEffect? {
    guard let current, mode == .normal else { return nil }
    let base = current.hasSuffix(".date") ? String(current.dropLast(".date".count)) : current
    for companion in ["\(current).clear", "\(current).remove", "\(base).clear"]
    where stops.contains(where: { $0.id == companion }) {
      return .press(companion)
    }
    return .clearValue(current)
  }

  /// `h` and `←` hand the keyboard back to the tasks — except that ← on a
  /// picker steps its value, as it always has.
  public func leave(byArrow: Bool) -> InspectorEffect {
    if byArrow, let current, currentKind == .adjustable { return .adjust(current, by: -1) }
    return .leave
  }

  // MARK: Editing

  /// Stops editing, on the same row. Giving up puts back what was typed over.
  @discardableResult
  public mutating func finishEditing(commit: Bool) -> InspectorEffect? {
    guard mode == .editing, let current else { return nil }
    mode = .normal
    return commit ? nil : .revert(current)
  }

  /// Tab and ⇧Tab inside a field: keep the text, move a row, and open it if
  /// it is a text row too, so a run of fields is filled in one go.
  public mutating func tab(forward: Bool) {
    finishEditing(commit: true)
    step(by: forward ? 1 : -1)
    if currentKind?.isText == true { mode = .editing }
  }

  /// The keyboard moved on its own — a click in a field, on a control, or
  /// away from the inspector. A field that took the caret is being edited;
  /// a control that took it is under the cursor; losing it ends any edit.
  public mutating func keyboardMoved(to id: String?) {
    guard let id else {
      mode = .normal
      return
    }
    guard let stop = stops.first(where: { $0.id == id }) else { return }
    current = id
    mode = stop.kind.isText ? .editing : .normal
  }
}
