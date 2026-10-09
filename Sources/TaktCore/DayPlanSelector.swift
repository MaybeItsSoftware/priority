import Foundation
import TaktRustCore

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
///
/// The Rust core's `next_up::plan`, which `WorkspaceStore.nextUpSnapshot`
/// runs without the candidates leaving the core: the running block, then the
/// Today column in its own order, then the overdue and the due today by
/// deadline, then what starts today. Each task once, under its first reason.
public enum DayPlanSelector {
  public static func plan(
    candidates: [NextUpCandidate],
    runningID: String? = nil,
    now: Date,
    calendar: Calendar = .current
  ) -> [DayPlanEntry] {
    planDay(
      candidates: candidates.map(\.core), runningId: runningID, nowMs: now.rankingMilliseconds,
      zone: calendar.timeZone.identifier
    ).map(DayPlanEntry.init)
  }
}
