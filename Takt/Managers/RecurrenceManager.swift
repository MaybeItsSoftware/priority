import Foundation
import Observation
import OSLog

@MainActor
@Observable class RecurrenceManager {
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "recurrence")
  @ObservationIgnored private let preferencesStore: PreferencesStore

  /// Maps task ID → raw recurrence rule string (e.g. "daily", "every 3 days").
  var recurrenceRulesByTaskId: [Int: String] = [:] {
    didSet {
      let encoded = Dictionary(uniqueKeysWithValues: recurrenceRulesByTaskId.map { (String($0.key), $0.value) })
      preferencesStore.set(encoded, for: .recurrenceRulesByTaskId)
    }
  }

  init(preferencesStore: PreferencesStore) {
    self.preferencesStore = preferencesStore
    let storedRules = preferencesStore.stringDictionary(.recurrenceRulesByTaskId)
    // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`: the stored keys
    // are strings, and "7" and "07" both parse to 7. A hand-edited plist or a
    // key written by an older build in a different format would trap at
    // launch under the strict initialiser. Last one wins; there is no better
    // tiebreak, and either beats a crash.
    self.recurrenceRulesByTaskId = Dictionary(
      storedRules.compactMap { key, value -> (Int, String)? in
        guard let id = Int(key) else { return nil }
        return (id, value)
      },
      uniquingKeysWith: { _, last in last }
    )
  }

  // MARK: - Recurrence rule storage

  /// Returns the recurrence rule for a task, or nil if none is set.
  func recurrenceRule(for task: CheckvistTask) -> RecurrenceRule? {
    guard let raw = recurrenceRulesByTaskId[task.id], !raw.isEmpty else { return nil }
    return RecurrenceRule(raw: raw)
  }

  /// Sets the recurrence rule for a task from a raw string.
  /// Returns an error message if the rule is unrecognised, nil on success.
  func setRecurrenceRule(_ raw: String, for task: CheckvistTask) -> String? {
    guard let rule = RecurrenceRule.from(raw) else {
      return "Unrecognised repeat rule: \"\(raw)\". Try: daily, weekdays, weekly, every 3 days, every monday."
    }
    recurrenceRulesByTaskId[task.id] = rule.raw
    return nil
  }

  /// Removes the recurrence rule for a task.
  func clearRecurrenceRule(for task: CheckvistTask) {
    recurrenceRulesByTaskId.removeValue(forKey: task.id)
  }

  // MARK: - Next occurrence computation

  /// Computes the next due date string for a completed recurring task.
  /// Returns nil if the task has no recurrence rule or the date cannot be calculated.
  /// The caller (coordinator) is responsible for creating the sibling task and transferring the rule.
  func computeNextOccurrence(
    for completedTask: CheckvistTask,
    parseDueDateString: (String) -> Date?
  ) -> (dueDateString: String, savedRule: String)? {
    guard let rule = recurrenceRule(for: completedTask) else { return nil }

    let baseDate: Date
    if let dueString = completedTask.due, !dueString.isEmpty,
       let parsedDue = parseDueDateString(dueString) {
      baseDate = parsedDue
    } else {
      baseDate = Date()
    }

    guard let nextDate = rule.nextDueDate(from: baseDate) else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let dueDateString = formatter.string(from: nextDate)

    return (dueDateString: dueDateString, savedRule: rule.raw)
  }

  /// Transfers a recurrence rule from a completed task to a newly created task,
  /// and cleans up the rule from the completed task.
  func transferRule(from completedTaskId: Int, to newTaskId: Int, rule: String) {
    recurrenceRulesByTaskId[newTaskId] = rule
    recurrenceRulesByTaskId.removeValue(forKey: completedTaskId)
  }

  // MARK: - Private helpers

  static func parseDueDateString(_ raw: String) -> Date? {
    let formatters: [DateFormatter] = [
      makeDueFormatter("yyyy-MM-dd HH:mm:ss Z"),
      makeDueFormatter("yyyy-MM-dd HH:mm:ss"),
      makeDueFormatter("yyyy-MM-dd"),
    ]
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
    for f in formatters {
      if let d = f.date(from: trimmed) { return d }
    }
    return nil
  }

  private static func makeDueFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
  }
}
