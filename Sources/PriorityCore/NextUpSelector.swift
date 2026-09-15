import Foundation

/// Why a task came out on top. The focus screen shows this, because "what
/// should I do next" is only answerable if you can see the reasoning and
/// disagree with it — an unexplained pick gets second-guessed every time.
public enum NextUpReason: String, Sendable, Equatable, CaseIterable {
  case daily
  case overdue
  case dueToday
  case dueSoon
  case today
  case importance
  case priority
  case order

  /// Sentence fragment, to be read after the task title.
  public var explanation: String {
    switch self {
    case .daily: return "today's contribution is still outstanding"
    case .overdue: return "it is past its due date"
    case .dueToday: return "it is due today"
    case .dueSoon: return "it is due shortly"
    case .today: return "you put it in Today"
    case .importance: return "it is the most important thing on the matrix"
    case .priority: return "it carries the highest priority"
    case .order: return "it is next in order"
    }
  }
}

/// Everything the ranker needs about one task, flattened out of the store.
///
/// A value type rather than a query so the scoring is testable without a
/// database, and so the same ranking can later be fed by something that isn't
/// `WorkspaceStore` at all.
public struct NextUpCandidate: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  /// True when a daily attached to this task is expected today. A daily whose
  /// contribution is already logged should simply not be passed in.
  public let isDailyDueToday: Bool
  public let dueAt: Date?
  /// A task scheduled for later is not a candidate until that moment arrives.
  /// This is what "schedule it for later" on the focus screen writes.
  public let startAt: Date?
  public let matrixUrgency: Int?
  public let matrixImportance: Int?
  /// 0 = none through 4 = urgent, matching the inspector's picker.
  public let priority: Int?
  public let estimateSeconds: Int?
  public let kanbanColumn: String?
  /// A position the user placed by hand. Present means the ranking has been
  /// overruled for this task, and it sits where it was put.
  public let focusRank: Int?
  public let sortOrder: Int
  public let createdAt: Date

  public init(
    id: String,
    title: String,
    isDailyDueToday: Bool = false,
    dueAt: Date? = nil,
    startAt: Date? = nil,
    matrixUrgency: Int? = nil,
    matrixImportance: Int? = nil,
    priority: Int? = nil,
    estimateSeconds: Int? = nil,
    kanbanColumn: String? = nil,
    focusRank: Int? = nil,
    sortOrder: Int = 0,
    createdAt: Date = .distantPast
  ) {
    self.id = id
    self.title = title
    self.isDailyDueToday = isDailyDueToday
    self.dueAt = dueAt
    self.startAt = startAt
    self.matrixUrgency = matrixUrgency
    self.matrixImportance = matrixImportance
    self.priority = priority
    self.estimateSeconds = estimateSeconds
    self.kanbanColumn = kanbanColumn
    self.focusRank = focusRank
    self.sortOrder = sortOrder
    self.createdAt = createdAt
  }
}

public struct ScoredNextUp: Sendable, Equatable, Identifiable {
  public let candidate: NextUpCandidate
  public let score: Double
  public let reason: NextUpReason

  public var id: String { candidate.id }

  public init(candidate: NextUpCandidate, score: Double, reason: NextUpReason) {
    self.candidate = candidate
    self.score = score
    self.reason = reason
  }
}

/// Picks what to do next from dailies, due dates, the matrix and manual order.
///
/// The score is additive rather than a strict tier list: a merely-important task
/// should be able to overtake something due in a fortnight, which a tier list
/// makes impossible. Each term carries its own `NextUpReason`, and the largest
/// term names the pick — so the score decides the order and the reason explains
/// it, without the two being able to disagree.
public enum NextUpSelector {
  /// The identifier of the Kanban column that means "I chose this for today".
  public static let todayColumnID = "today"

  /// Due dates stop contributing beyond this, so a task due in three months
  /// doesn't quietly outrank one you actually flagged.
  public static let dueHorizonDays = 14

  public static func next(
    from candidates: [NextUpCandidate],
    now: Date = .now,
    calendar: Calendar = .current
  ) -> ScoredNextUp? {
    rank(candidates, now: now, calendar: calendar).first
  }

  /// Highest score first. Candidates scheduled past `now` are dropped entirely
  /// rather than scored to zero — "later" means absent, not unappealing.
  public static func rank(
    _ candidates: [NextUpCandidate],
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [ScoredNextUp] {
    let scored = candidates
      .filter { ($0.startAt ?? .distantPast) <= now }
      .map { score($0, now: now, calendar: calendar) }
    return place(pinned: scored.filter { $0.candidate.focusRank != nil },
                 among: scored.filter { $0.candidate.focusRank == nil }.sorted(by: byScore))
  }

  /// Slots hand-placed tasks into the scored order at the positions they were
  /// put, leaving everything else ranked normally around them.
  ///
  /// A pin is a *position*, not a promotion. The alternative — letting any
  /// pinned task outrank every unpinned one — means the first time you nudge
  /// something the whole ladder freezes, because from then on the pinned set
  /// only ever grows and the ranking has nothing left to order.
  ///
  /// A pin whose index has been passed takes the next free slot rather than
  /// being dropped, so two tasks pinned to the same place still both appear.
  private static func place(pinned: [ScoredNextUp], among free: [ScoredNextUp]) -> [ScoredNextUp] {
    guard !pinned.isEmpty else { return free }
    let queue = pinned.sorted {
      let left = $0.candidate.focusRank ?? 0
      let right = $1.candidate.focusRank ?? 0
      return left == right ? $0.candidate.id < $1.candidate.id : left < right
    }
    var result: [ScoredNextUp] = []
    result.reserveCapacity(queue.count + free.count)
    var nextPinned = 0
    var nextFree = 0
    while result.count < queue.count + free.count {
      let claimsThisSlot = nextPinned < queue.count
        && (queue[nextPinned].candidate.focusRank ?? 0) <= result.count
      if claimsThisSlot || nextFree == free.count {
        result.append(queue[nextPinned])
        nextPinned += 1
      } else {
        result.append(free[nextFree])
        nextFree += 1
      }
    }
    return result
  }

  private static func byScore(_ lhs: ScoredNextUp, _ rhs: ScoredNextUp) -> Bool {
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    // A shorter job first, among equals: finishing something is worth more
    // than starting the same-sized something else.
    let lhsEstimate = lhs.candidate.estimateSeconds ?? Int.max
    let rhsEstimate = rhs.candidate.estimateSeconds ?? Int.max
    if lhsEstimate != rhsEstimate { return lhsEstimate < rhsEstimate }
    if lhs.candidate.sortOrder != rhs.candidate.sortOrder {
      return lhs.candidate.sortOrder < rhs.candidate.sortOrder
    }
    if lhs.candidate.createdAt != rhs.candidate.createdAt {
      return lhs.candidate.createdAt < rhs.candidate.createdAt
    }
    return lhs.candidate.id < rhs.candidate.id
  }

  public static func score(
    _ candidate: NextUpCandidate,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> ScoredNextUp {
    var terms: [(NextUpReason, Double)] = []

    if candidate.isDailyDueToday {
      // Deliberately the largest single term. A daily is the one thing whose
      // value is destroyed by deferring it: a task put off until tomorrow is
      // the same task, a daily put off until tomorrow is a gap in the run.
      terms.append((.daily, 1000))
    }

    if let dueAt = candidate.dueAt {
      let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueAt)).day ?? 0
      if days < 0 {
        // Capped, or a task forgotten for a year buries everything behind it
        // forever and the queue stops being usable.
        terms.append((.overdue, 600 + Double(min(-days, 30)) * 10))
      } else if days == 0 {
        terms.append((.dueToday, 500))
      } else if days <= dueHorizonDays {
        terms.append((.dueSoon, 400 * (1 - Double(days) / Double(dueHorizonDays + 1))))
      }
    }

    if candidate.kanbanColumn == todayColumnID {
      terms.append((.today, 250))
    }

    let importance = candidate.matrixImportance ?? 0
    let urgency = candidate.matrixUrgency ?? 0
    if importance > 0 || urgency > 0 {
      terms.append((.importance, Double(importance) * 120 + Double(urgency) * 80))
    }

    if let priority = candidate.priority, priority > 0 {
      terms.append((.priority, Double(priority) * 30))
    }

    // Always present, so an untouched list still produces a pick rather than an
    // arbitrary one — and small enough never to outrank a real signal.
    terms.append((.order, 1))

    let total = terms.reduce(0) { $0 + $1.1 }
    let dominant = terms.max { $0.1 < $1.1 }?.0 ?? .order
    return ScoredNextUp(candidate: candidate, score: total, reason: dominant)
  }
}
