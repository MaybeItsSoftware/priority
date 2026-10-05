import Foundation

public enum NextUpReason: String, Sendable, Equatable, CaseIterable {
  case daily, overdue, dueToday, dueSoon, today, importance, priority, order
  case condition, started, deadlineRisk

  public var explanation: String {
    switch self {
    case .daily: "today's contribution is still outstanding"
    case .overdue: "it is past its due date"
    case .dueToday: "it is due today"
    case .dueSoon: "it is due shortly"
    case .today: "you put it in Today"
    case .importance: "it is important on the matrix"
    case .priority: "it carries a high priority"
    case .order: "it is next in order"
    case .condition: "its required conditions are available now"
    case .started: "its start time has arrived"
    case .deadlineRisk: "its remaining work puts the deadline at risk"
    }
  }
}

public enum FocusTimeMode: String, Codable, CaseIterable, Sendable {
  case progress, finish
}

public struct FocusContext: Equatable, Sendable {
  public var conditionIDs: Set<String>
  public var endsAt: Date?
  public var mode: FocusTimeMode

  public init(conditionIDs: Set<String> = [], endsAt: Date? = nil, mode: FocusTimeMode = .progress) {
    self.conditionIDs = conditionIDs
    self.endsAt = endsAt
    self.mode = mode
  }
}

public struct NextUpCandidate: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let isDailyDueToday: Bool
  public let dueAt: Date?
  public let startAt: Date?
  public let matrixUrgency: Int?
  public let matrixImportance: Int?
  public let priority: Int?
  public let estimateSeconds: Int?
  public let kanbanColumn: String?
  public let focusRank: Int?
  public let sortOrder: Int
  public let createdAt: Date
  public let dueDate: String?
  public let requirementGroups: [[String]]
  public let loggedSeconds: Int
  public let minimumBlockSeconds: Int?
  public let requiresSingleSitting: Bool
  public let dailyRemainingSeconds: Int?
  public let dailyUnavailable: TaskUnavailableReason?

  public init(
    id: String, title: String, isDailyDueToday: Bool = false, dueAt: Date? = nil,
    startAt: Date? = nil, matrixUrgency: Int? = nil, matrixImportance: Int? = nil,
    priority: Int? = nil, estimateSeconds: Int? = nil, kanbanColumn: String? = nil,
    focusRank: Int? = nil, sortOrder: Int = 0, createdAt: Date = .distantPast,
    dueDate: String? = nil, requirementGroups: [[String]] = [], loggedSeconds: Int = 0,
    minimumBlockSeconds: Int? = nil, requiresSingleSitting: Bool = false,
    dailyRemainingSeconds: Int? = nil, dailyUnavailable: TaskUnavailableReason? = nil
  ) {
    self.id = id; self.title = title; self.isDailyDueToday = isDailyDueToday
    self.dueAt = dueAt; self.startAt = startAt; self.matrixUrgency = matrixUrgency
    self.matrixImportance = matrixImportance; self.priority = priority
    self.estimateSeconds = estimateSeconds; self.kanbanColumn = kanbanColumn
    self.focusRank = focusRank; self.sortOrder = sortOrder; self.createdAt = createdAt
    self.dueDate = dueDate; self.requirementGroups = requirementGroups
    self.loggedSeconds = loggedSeconds; self.minimumBlockSeconds = minimumBlockSeconds
    self.requiresSingleSitting = requiresSingleSitting; self.dailyRemainingSeconds = dailyRemainingSeconds
    self.dailyUnavailable = dailyUnavailable
  }

  public var remainingSeconds: Int? {
    if let dailyRemainingSeconds { return max(0, dailyRemainingSeconds) }
    return estimateSeconds.map { max(0, $0 - max(0, loggedSeconds)) }
  }

  public func effectiveDeadline(calendar: Calendar) -> Date? {
    if let dueDate, let day = TaskCalendarDate.date(dueDate, calendar: calendar) {
      return calendar.date(byAdding: .day, value: 1, to: day)
    }
    return dueAt
  }
}

/// Calendar dates stay dates across daylight-saving and timezone changes.
public enum TaskCalendarDate {
  public static func string(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static func date(_ value: String, calendar: Calendar = .current) -> Date? {
    let pieces = value.split(separator: "-").compactMap { Int($0) }
    guard pieces.count == 3 else { return nil }
    let parts = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
    guard let date = calendar.date(from: parts), string(date, calendar: calendar) == value else { return nil }
    return date
  }
}

public enum TaskUnavailableReason: Equatable, Sendable {
  case startsLater(Date), missingConditions([[String]]), insufficientTime(Int), needsEstimate, expiredWindow
  case dailyNotScheduled, dailyAlreadyMet
}

public struct BlockedFocusTask: Identifiable, Equatable, Sendable {
  public let candidate: NextUpCandidate
  public let reasons: [TaskUnavailableReason]
  public var id: String { candidate.id }
}

public struct FocusRanking: Sendable {
  public let ranked: [ScoredNextUp]
  public let blocked: [BlockedFocusTask]
  public let nextEvaluationAt: Date?
}

public enum TaskAvailabilityPolicy {
  public static func reasons(
    for task: NextUpCandidate, context: FocusContext, now: Date
  ) -> [TaskUnavailableReason] {
    var result: [TaskUnavailableReason] = []
    if let dailyUnavailable = task.dailyUnavailable { result.append(dailyUnavailable) }
    if let start = task.startAt, start > now { result.append(.startsLater(start)) }
    let missing = task.requirementGroups.filter { Set($0).isDisjoint(with: context.conditionIDs) }
    if !missing.isEmpty { result.append(.missingConditions(missing)) }
    let window = context.endsAt.map { max(0, $0.timeIntervalSince(now)) }
    if let window, window < 60 { result.append(.expiredWindow) }
    if task.requiresSingleSitting || context.mode == .finish {
      guard let remaining = task.remainingSeconds, remaining > 0 else {
        result.append(.needsEstimate)
        return result
      }
      let needed = max(60, remaining, task.minimumBlockSeconds ?? 60)
      if let window, Double(needed) > window { result.append(.insufficientTime(needed)) }
    } else if let window, Double(max(60, task.minimumBlockSeconds ?? 60)) > window {
      result.append(.insufficientTime(max(60, task.minimumBlockSeconds ?? 60)))
    }
    return result
  }

  public static func plannedSeconds(for task: NextUpCandidate, requested: Int?, context: FocusContext, now: Date) -> Int {
    let needed = task.requiresSingleSitting ? (task.remainingSeconds ?? 60) : 60
    let seconds = max(60, needed, task.minimumBlockSeconds ?? 60,
                      requested ?? suggestedSeconds(for: task, context: context, now: now))
    return context.endsAt.map { min(seconds, max(0, Int($0.timeIntervalSince(now)))) } ?? seconds
  }

  public static func suggestedSeconds(for task: NextUpCandidate, context: FocusContext, now: Date) -> Int {
    let remaining = task.remainingSeconds.flatMap { $0 > 0 ? $0 : nil }
    let suggested = max(60, task.minimumBlockSeconds ?? 60, remaining ?? 25 * 60)
    guard let end = context.endsAt, !task.requiresSingleSitting else { return suggested }
    return min(suggested, max(0, Int(end.timeIntervalSince(now))))
  }
}

public struct ScoredNextUp: Sendable, Equatable, Identifiable {
  public let candidate: NextUpCandidate
  public let score: Double
  public let reason: NextUpReason
  public let explanation: String
  public var id: String { candidate.id }

  public init(candidate: NextUpCandidate, score: Double, reason: NextUpReason, explanation: String? = nil) {
    self.candidate = candidate; self.score = score; self.reason = reason
    self.explanation = explanation ?? reason.explanation
  }
}

/// Availability is evaluated before a deterministic precedence tuple. Numeric
/// scores are retained for compatibility; they never override deadline ordering.
public enum NextUpSelector {
  public static let todayColumnID = "today"
  public static let dueHorizonDays = 14
  public static let minimumDeadlineBuffer: Double = 300
  public static let deadlineBufferFraction: Double = 0.2

  public static func next(from candidates: [NextUpCandidate], now: Date = .now,
                          calendar: Calendar = .current) -> ScoredNextUp? {
    rank(candidates, now: now, calendar: calendar).first
  }

  public static func rank(_ candidates: [NextUpCandidate], now: Date = .now,
                          calendar: Calendar = .current, context: FocusContext = FocusContext()) -> [ScoredNextUp] {
    evaluate(candidates, now: now, calendar: calendar, context: context).ranked
  }

  public static func evaluate(_ candidates: [NextUpCandidate], now: Date = .now,
                              calendar: Calendar = .current, context: FocusContext = FocusContext()) -> FocusRanking {
    var available: [NextUpCandidate] = []
    var blocked: [BlockedFocusTask] = []
    for task in candidates {
      let reasons = TaskAvailabilityPolicy.reasons(for: task, context: context, now: now)
      if reasons.isEmpty { available.append(task) } else { blocked.append(BlockedFocusTask(candidate: task, reasons: reasons)) }
    }
    let sorted = available.sorted { precedes($0, $1, now: now, calendar: calendar) }
    // Only non-deadline work has positional pins. Deadline ties can use pins,
    // but a pin cannot reverse lateness or deadline slack.
    var ranked: [NextUpCandidate] = []
    var index = 0
    while index < sorted.count {
      let key = primary(sorted[index], now: now, calendar: calendar)
      var end = index + 1
      while end < sorted.count && primary(sorted[end], now: now, calendar: calendar) == key { end += 1 }
      ranked += place(Array(sorted[index..<end]))
      index = end
    }
    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    var boundaries = candidates.flatMap { task -> [Date] in
      var dates = [task.startAt, task.effectiveDeadline(calendar: calendar)].compactMap { $0 }
      if task.dueDate == nil, let deadline = task.dueAt { dates.append(deadline.addingTimeInterval(0.001)) }
      if let deadline = task.effectiveDeadline(calendar: calendar), let work = task.remainingSeconds, work > 0 {
        dates.append(deadline.addingTimeInterval(-Double(work) - buffer(work)))
      }
      if let end = context.endsAt {
        dates.append(end.addingTimeInterval(-Double(max(60, task.minimumBlockSeconds ?? 60)) + 0.001))
        if let work = task.remainingSeconds, context.mode == .finish || task.requiresSingleSitting {
          dates.append(end.addingTimeInterval(-Double(max(60, work, task.minimumBlockSeconds ?? 60)) + 0.001))
        }
      }
      return dates
    }
    boundaries += [context.endsAt, nextDay].compactMap { $0 }
    return FocusRanking(
      ranked: ranked.map { score($0, now: now, calendar: calendar) },
      blocked: blocked.sorted { precedes($0.candidate, $1.candidate, now: now, calendar: calendar) },
      nextEvaluationAt: boundaries.filter { $0 > now }.min())
  }

  private static func buffer(_ seconds: Int) -> Double {
    max(minimumDeadlineBuffer, Double(seconds) * deadlineBufferFraction)
  }

  private static func primary(_ task: NextUpCandidate, now: Date, calendar: Calendar) -> [Double] {
    guard let due = task.effectiveDeadline(calendar: calendar) else { return [3, 0] }
    let late = task.dueDate == nil ? due < now : due <= now
    if late { return [0, due.timeIntervalSince1970] }
    let isToday = task.dueDate.map { $0 == TaskCalendarDate.string(now, calendar: calendar) }
      ?? calendar.isDate(due, inSameDayAs: now)
    if isToday { return [1, due.timeIntervalSince1970, task.createdAt.timeIntervalSince1970] }
    if let work = task.remainingSeconds, work > 0 {
      let slack = due.timeIntervalSince(now) - Double(work) - buffer(work)
      if slack <= 0 { return [2, slack] }
    }
    return [3, 0]
  }

  private static func precedes(_ left: NextUpCandidate, _ right: NextUpCandidate,
                               now: Date, calendar: Calendar) -> Bool {
    let lhs = primary(left, now: now, calendar: calendar)
    let rhs = primary(right, now: now, calendar: calendar)
    if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
    func secondary(_ task: NextUpCandidate) -> [Double] {
      let commitment = task.isDailyDueToday || task.kanbanColumn == todayColumnID
      let due = task.effectiveDeadline(calendar: calendar)
      let days = due.map { max(0, $0.timeIntervalSince(now) / 86_400) } ?? Double.infinity
      return [task.requirementGroups.isEmpty ? 1 : 0, task.startAt == nil ? 1 : 0,
              commitment ? 0 : 1, -Double(task.matrixImportance ?? 0), -Double(task.priority ?? 0),
              days <= Double(dueHorizonDays) ? days : Double.infinity,
              -Double(task.matrixUrgency ?? 0), task.createdAt.timeIntervalSince1970,
              Double(task.remainingSeconds ?? Int.max), Double(task.sortOrder)]
    }
    let a = secondary(left), b = secondary(right)
    return a == b ? left.id < right.id : a.lexicographicallyPrecedes(b)
  }

  private static func place(_ tasks: [NextUpCandidate]) -> [NextUpCandidate] {
    let pinned = tasks.filter { $0.focusRank != nil }.sorted {
      ($0.focusRank ?? 0, $0.id) < ($1.focusRank ?? 0, $1.id)
    }
    let free = tasks.filter { $0.focusRank == nil }
    var result: [NextUpCandidate] = []
    var pin = 0, unpinned = 0
    while result.count < tasks.count {
      if pin < pinned.count && ((pinned[pin].focusRank ?? 0) <= result.count || unpinned == free.count) {
        result.append(pinned[pin]); pin += 1
      } else { result.append(free[unpinned]); unpinned += 1 }
    }
    return result
  }

  public static func score(_ task: NextUpCandidate, now: Date = .now,
                           calendar: Calendar = .current) -> ScoredNextUp {
    let key = primary(task, now: now, calendar: calendar)
    let reason: NextUpReason
    var explanation: String?
    switch key[0] {
    case 0:
      reason = .overdue
      let days = max(0, Int(now.timeIntervalSince(task.effectiveDeadline(calendar: calendar) ?? now) / 86_400))
      explanation = days > 0 ? "overdue by \(days) days" : "past its deadline"
    case 1:
      reason = .dueToday
      let age = Int(max(0, now.timeIntervalSince(task.createdAt)) / 86_400)
      if age >= 30 { explanation = "due today; added \(age) days ago" }
    case 2: reason = .deadlineRisk
    default:
      if !task.requirementGroups.isEmpty {
        reason = .condition
      } else if task.startAt != nil {
        reason = .started
      } else if task.isDailyDueToday {
        reason = .daily
      } else if task.kanbanColumn == todayColumnID {
        reason = .today
      } else if (task.matrixImportance ?? 0) > 0 || (task.matrixUrgency ?? 0) > 0 {
        reason = .importance
      } else if (task.priority ?? 0) > 0 {
        reason = .priority
      } else if let due = task.effectiveDeadline(calendar: calendar),
                due.timeIntervalSince(now) <= Double(dueHorizonDays) * 86_400 {
        reason = .dueSoon
      } else {
        reason = .order
      }
    }
    return ScoredNextUp(candidate: task, score: (4 - key[0]) * 1000, reason: reason, explanation: explanation)
  }
}
