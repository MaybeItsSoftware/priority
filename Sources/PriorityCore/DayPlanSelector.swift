import Foundation

/// Why a task is part of today.
///
/// The order of the cases is the order the day is read in, so a plan can be
/// sorted by reason alone.
public enum DayPlanReason: String, Sendable, Codable, CaseIterable {
  /// The block currently underway. It heads the day wherever it came from.
  case running
  /// Put in the Today column by hand. A deliberate choice outranks a derived
  /// one, because the derived ones are what the user was answering when they
  /// made it.
  case planned
  /// Past its deadline. Today's problem whether or not anyone planned it.
  case overdue
  /// Its deadline falls today.
  case dueToday
  /// Its start date is today — the day it was scheduled to be begun.
  case startsToday

  /// Short enough to sit on a card beside the title.
  public var label: String {
    switch self {
    case .running: return "Running"
    case .planned: return "Planned"
    case .overdue: return "Overdue"
    case .dueToday: return "Due today"
    case .startsToday: return "Starts today"
    }
  }
}

/// One task in the day, and what put it there.
public struct DayPlanEntry: Sendable, Equatable, Identifiable {
  public let id: String
  public let reason: DayPlanReason

  public init(id: String, reason: DayPlanReason) {
    self.id = id
    self.reason = reason
  }
}

/// Which tasks make up today.
///
/// The Today column is a list you arrange by hand, but a day is not only what
/// you remembered to put there: a deadline that lands today, or a start date
/// that has come round, belongs to the day whether or not anyone moved it.
/// This gathers all of them into one ordered list without writing anything
/// back — nothing is *moved* into the column, so tomorrow's derivation is not
/// polluted by today's, and clearing the column still clears the plan.
public enum DayPlanSelector {
  public static func plan(
    candidates: [NextUpCandidate],
    todayColumnID: String = NextUpSelector.todayColumnID,
    runningID: String? = nil,
    now: Date,
    calendar: Calendar = .current
  ) -> [DayPlanEntry] {
    let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
      ?? now

    var entries: [DayPlanEntry] = []
    var claimed: Set<String> = []

    func claim(_ candidate: NextUpCandidate, _ reason: DayPlanReason) {
      guard !claimed.contains(candidate.id) else { return }
      claimed.insert(candidate.id)
      entries.append(DayPlanEntry(id: candidate.id, reason: reason))
    }

    if let runningID, let running = candidates.first(where: { $0.id == runningID }) {
      claim(running, .running)
    }

    // The column's own arrangement is the one thing here a person chose, so it
    // is preserved exactly rather than re-sorted by urgency.
    for candidate in candidates.filter({ $0.kanbanColumn == todayColumnID })
      .sorted(by: plannedOrder) {
      claim(candidate, .planned)
    }

    // A deadline already passed reads before one merely arriving, and within
    // each the nearer deadline first.
    let dated = candidates
      .compactMap { candidate -> (NextUpCandidate, Date)? in
        guard let deadline = candidate.effectiveDeadline(calendar: calendar) else { return nil }
        return (candidate, deadline)
      }
      .sorted { $0.1 < $1.1 }
    for (candidate, deadline) in dated where deadline <= now {
      claim(candidate, .overdue)
    }
    for (candidate, deadline) in dated where deadline > now && deadline <= endOfToday {
      claim(candidate, .dueToday)
    }

    for candidate in candidates
      .compactMap({ candidate -> (NextUpCandidate, Date)? in
        guard let start = candidate.startAt, calendar.isDate(start, inSameDayAs: now) else {
          return nil
        }
        return (candidate, start)
      })
      .sorted(by: { $0.1 < $1.1 })
      .map(\.0) {
      claim(candidate, .startsToday)
    }

    return entries
  }

  /// A rank given by hand wins; without one, the list's own order, and a
  /// stable tiebreak so the day does not reshuffle between reads.
  private static func plannedOrder(_ lhs: NextUpCandidate, _ rhs: NextUpCandidate) -> Bool {
    switch (lhs.focusRank, rhs.focusRank) {
    case let (left?, right?) where left != right: return left < right
    case (.some, .none): return true
    case (.none, .some): return false
    default: break
    }
    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
    return lhs.id < rhs.id
  }
}
