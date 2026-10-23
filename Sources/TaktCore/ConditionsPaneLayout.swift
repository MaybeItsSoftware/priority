import Foundation

/// A row of the Conditions tab the keyboard can stand on.
///
/// The tab has two halves — what is available now, and the conditions
/// themselves — and one cursor walks down through both.
public enum ConditionsPaneRow: Hashable, Sendable {
  /// Where you are, as one row: `←`/`→` step through the places.
  case location
  /// A condition in the "Available now" half: Space turns it on or off.
  case available(String)
  /// How much time you have: `←`/`→` take or give a quarter of an hour,
  /// typing sets it.
  case time
  /// Whether only what fits in that time is offered. Only with a time.
  case finishOnly
  /// When what you have said stops counting.
  case expiry
  /// Whether each day starts afresh: Space turns it on or off.
  case dayStart
  /// The hour the day changes: `←`/`→` step it.
  case dayStartHour
  /// The conditions each day starts with: Return ticks them. Only while
  /// each day starts afresh.
  case dayStartConditions
  /// The new-condition row: Return puts the caret in its field.
  case add
  /// A condition in the "Conditions" half: rename, file, move, merge.
  case condition(String)
  /// A folded category's heading, by its section id: `z` unfolds it.
  case folded(String)
  /// The heading of the archived conditions: `z` shows or hides them.
  case archived

  /// The condition the row is about, if it is about one.
  public var conditionID: String? {
    switch self {
    case .available(let id), .condition(let id): id
    case .location, .time, .finishOnly, .expiry, .dayStart, .dayStartHour, .dayStartConditions, .add, .folded,
      .archived:
      nil
    }
  }

  /// Whether it is a folded heading or the archived heading.
  public var isFolded: Bool {
    switch self {
    case .folded, .archived: true
    default: false
    }
  }

  /// The scroll anchor for the row.
  public var anchor: String {
    switch self {
    case .location: "location"
    case .time: "time"
    case .finishOnly: "finishOnly"
    case .expiry: "expiry"
    case .dayStart: "dayStart"
    case .dayStartHour: "dayStartHour"
    case .dayStartConditions: "dayStartConditions"
    case .available(let id): "available.\(id)"
    case .add: "add"
    case .condition(let id): "condition.\(id)"
    case .folded(let id): "folded.\(id)"
    case .archived: "archived"
    }
  }
}

/// Which rows the Conditions tab offers the cursor, and where a cursor whose
/// row has gone lands. Pure, so the folding rules are tested without the app.
public enum ConditionsPaneLayout {
  /// One heading of the Conditions half: its section id and its live
  /// conditions in order.
  public struct Section: Equatable, Sendable {
    public let id: String
    public let conditionIDs: [String]

    public init(id: String, conditionIDs: [String]) {
      self.id = id
      self.conditionIDs = conditionIDs
    }
  }

  /// Top to bottom: where you are (with `hasPlaces`), your free time and
  /// whether to finish within it (only with `hasTimeLimit`), the other
  /// conditions you can say hold — the other settings first, as the core
  /// orders them — and when it all expires; with `dayStart`, how each day
  /// starts (what it starts with only when `startsAfresh`); the new-condition row,
  /// then each heading's conditions — or, folded, the heading alone — and
  /// last the archived heading (when there are any) and, shown, the archived
  /// conditions under it.
  public static func rows(
    available: [String], sections: [Section], folded: Set<String>,
    archived: [String], showsArchived: Bool, hasPlaces: Bool = false, hasTimeLimit: Bool = false,
    dayStart: Bool = false, startsAfresh: Bool = false
  ) -> [ConditionsPaneRow] {
    var rows: [ConditionsPaneRow] = hasPlaces ? [.location] : []
    rows += hasTimeLimit ? [.time, .finishOnly] : [.time]
    rows += available.map(ConditionsPaneRow.available)
    rows.append(.expiry)
    if dayStart { rows += startsAfresh ? [.dayStart, .dayStartHour, .dayStartConditions] : [.dayStart, .dayStartHour] }
    rows.append(.add)
    for section in sections where !section.conditionIDs.isEmpty {
      if folded.contains(section.id) {
        rows.append(.folded(section.id))
      } else {
        rows += section.conditionIDs.map(ConditionsPaneRow.condition)
      }
    }
    if !archived.isEmpty {
      rows.append(.archived)
      if showsArchived { rows += archived.map(ConditionsPaneRow.condition) }
    }
    return rows
  }

  /// Where the cursor is drawn. One whose row has gone lands on the nearest
  /// thing still about the same condition: the condition in the other half,
  /// else its folded heading, else the archived heading; otherwise the top.
  public static func landing(
    _ cursor: ConditionsPaneRow?, in rows: [ConditionsPaneRow], sections: [Section]
  ) -> ConditionsPaneRow {
    guard let cursor else { return rows.first ?? .add }
    if rows.contains(cursor) { return cursor }
    // Clearing the time takes its finish row with it, and no longer
    // starting each day afresh the row of what it starts with.
    if cursor == .finishOnly, rows.contains(.time) { return .time }
    if cursor == .dayStartConditions, rows.contains(.dayStart) { return .dayStart }
    if let id = cursor.conditionID {
      if rows.contains(.condition(id)) { return .condition(id) }
      if let section = sections.first(where: { $0.conditionIDs.contains(id) }), rows.contains(.folded(section.id)) {
        return .folded(section.id)
      }
      if rows.contains(.archived), !sections.contains(where: { $0.conditionIDs.contains(id) }) { return .archived }
    }
    if case .folded(let sectionID) = cursor,
      let first = sections.first(where: { $0.id == sectionID })?.conditionIDs.first,
      rows.contains(.condition(first)) {
      return .condition(first)
    }
    return rows.first ?? .add
  }

  /// The section a row belongs to in the Conditions half: its own heading
  /// for a folded one, the condition's heading for a condition.
  public static func section(of row: ConditionsPaneRow, in sections: [Section]) -> Section? {
    switch row {
    case .folded(let id): sections.first { $0.id == id }
    case .condition(let id), .available(let id): sections.first { $0.conditionIDs.contains(id) }
    case .location, .time, .finishOnly, .expiry, .dayStart, .dayStartHour, .dayStartConditions, .add, .archived: nil
    }
  }
}
