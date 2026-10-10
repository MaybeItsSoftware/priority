import Foundation
import Observation
import OSLog

@MainActor
@Observable class StartDateManager {
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "startdate")
  @ObservationIgnored private let preferencesStore: PreferencesStore

  /// Maps task ID → start date string (same format as `due`).
  var taskStartDatesByTaskId: [Int: String] = [:] {
    didSet {
      let encoded = Dictionary(uniqueKeysWithValues: taskStartDatesByTaskId.map { (String($0.key), $0.value) })
      preferencesStore.set(encoded, for: .taskStartDatesByTaskId)
    }
  }

  @ObservationIgnored var dateResolver: ((String) -> String)?

  init(
    preferencesStore: PreferencesStore
  ) {
    self.preferencesStore = preferencesStore
    let storedStartDates = preferencesStore.stringDictionary(.taskStartDatesByTaskId)
    // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`: the stored keys
    // are strings, and "7" and "07" both parse to 7. A hand-edited plist or a
    // key written by an older build in a different format would trap at
    // launch under the strict initialiser. Last one wins; there is no better
    // tiebreak, and either beats a crash.
    self.taskStartDatesByTaskId = Dictionary(
      storedStartDates.compactMap { key, value -> (Int, String)? in
        guard let id = Int(key) else { return nil }
        return (id, value)
      },
      uniquingKeysWith: { _, last in last }
    )
  }

  // MARK: - Start date accessors

  /// Returns the start date string for a task, or nil if unset.
  func startDateString(for task: CheckvistTask) -> String? {
    let value = taskStartDatesByTaskId[task.id]
    return value?.isEmpty == false ? value : nil
  }

  /// Returns the parsed start Date for a task, or nil if unset / unparseable.
  func startDate(for task: CheckvistTask) -> Date? {
    guard let raw = startDateString(for: task) else { return nil }
    return parseStartDateString(raw)
  }

  // MARK: - Mutations

  func setStartDate(for task: CheckvistTask, rawInput: String) {
    let resolved = dateResolver?(rawInput) ?? rawInput
    taskStartDatesByTaskId[task.id] = resolved
  }

  func clearStartDate(for task: CheckvistTask) {
    taskStartDatesByTaskId.removeValue(forKey: task.id)
  }

  // MARK: - Display helpers

  /// Human-readable label for display in the task row badge.
  func startDateLabel(for task: CheckvistTask) -> String? {
    guard let raw = startDateString(for: task) else { return nil }
    if raw.lowercased() == "asap" { return "start: ASAP" }
    guard let date = parseStartDateString(raw) else { return raw }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let start = calendar.startOfDay(for: date)
    if start == today { return "starts today" }
    if start == tomorrow { return "starts tomorrow" }
    if start < today { return "started \(shortLabel(date))" }
    return "starts \(shortLabel(date))"
  }

  func startDateIsInFuture(for task: CheckvistTask) -> Bool {
    guard let date = startDate(for: task) else { return false }
    return date > Date()
  }

  // MARK: - Private helpers

  private func parseStartDateString(_ raw: String) -> Date? {
    let formatters: [DateFormatter] = [
      makeFormatter("yyyy-MM-dd HH:mm:ss Z"),
      makeFormatter("yyyy-MM-dd HH:mm:ss"),
      makeFormatter("yyyy-MM-dd"),
    ]
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
    for f in formatters {
      if let d = f.date(from: trimmed) { return d }
    }
    return nil
  }

  private func makeFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
  }

  private func shortLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: date)
  }
}
