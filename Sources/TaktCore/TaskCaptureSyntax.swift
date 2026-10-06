import Foundation

/// What a typed task says about itself beyond its title.
///
/// Typing `Write the release notes 45m #work @fri !1` into the add field files
/// a task called "Write the release notes" with a 45-minute estimate, the tag
/// `work`, due on Friday, at priority 1 — the four things you would otherwise
/// open the task again to set, straight after creating it, every time.
///
/// Only the *trailing* words are read, and only while every one of them is a
/// token. The first word from the end that is not one stops the scan, so a
/// title is never rewritten in the middle: `Read 30 pages` and `Email bob
/// @home` keep every word, and `Buy 2m of cable` keeps its `2m`. The field
/// shows what it found before Return is pressed, which is what makes a bare
/// `30m` safe to accept without a prefix.
///
/// The first word is never read as a token: a task called `30m` is odd, but a
/// task with no title at all is not a task.
public struct TaskCapture: Equatable, Sendable {
  public var title: String
  public var estimateSeconds: Int?
  /// The start of the day it is due, the same instant the `Due today` and
  /// `Due tomorrow` commands write.
  public var dueAt: Date?
  public var tags: [String]
  /// 1 to 4, the range the workspace stores.
  public var priority: Int?

  public init(
    title: String, estimateSeconds: Int? = nil, dueAt: Date? = nil, tags: [String] = [],
    priority: Int? = nil
  ) {
    self.title = title
    self.estimateSeconds = estimateSeconds
    self.dueAt = dueAt
    self.tags = tags
    self.priority = priority
  }

  /// Whether anything beyond the title was found.
  public var hasDetails: Bool {
    estimateSeconds != nil || dueAt != nil || !tags.isEmpty || priority != nil
  }

  /// Parses `text` as typed into an add field. See the type for the rules.
  public static func parse(
    _ text: String, now: Date = .now, calendar: Calendar = .current
  ) -> TaskCapture {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var capture = TaskCapture(title: trimmed)
    var tags: [String] = []

    // The first word is always the title's, so the scan cannot leave it empty.
    scan: while words.count > 1, let last = words.last {
      guard let token = TaskCaptureToken(last, now: now, calendar: calendar) else { break }
      // A second token of a kind already found ends the scan: the last one
      // typed wins, and the earlier one stays in the title where it can be
      // seen, rather than being silently thrown away.
      switch token {
      case .estimate(let seconds):
        guard capture.estimateSeconds == nil else { break scan }
        capture.estimateSeconds = seconds
      case .due(let date):
        guard capture.dueAt == nil else { break scan }
        capture.dueAt = date
      case .priority(let value):
        guard capture.priority == nil else { break scan }
        capture.priority = value
      case .tag(let tag):
        // A repeated tag is harmless, so it is folded rather than ending the
        // scan — keeping the spelling and place of the first one typed.
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        tags.insert(tag, at: 0)
      }
      words.removeLast()
    }

    guard capture.hasDetails || !tags.isEmpty else { return capture }
    capture.title = words.joined(separator: " ")
    capture.tags = tags
    return capture
  }

  /// Short labels for what was found, in the order the field shows them:
  /// `45m`, `Fri 3 Oct`, `#work`, `!1`.
  public func detailLabels(now: Date = .now, calendar: Calendar = .current) -> [String] {
    var labels: [String] = []
    if let estimateSeconds { labels.append(Self.durationLabel(estimateSeconds)) }
    if let dueAt { labels.append(Self.dueLabel(dueAt, now: now, calendar: calendar)) }
    labels += tags.map { "#\($0)" }
    if let priority { labels.append("!\(priority)") }
    return labels
  }

  static func durationLabel(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }

  /// A day and a time of day, as the follow-up field reads them: the add
  /// field's date words (`@fri`, `tomorrow`, `3d`, `2026-10-08`, each with or
  /// without the `@`), a time (`9am`, `9:30pm`, `14:00`, `noon`), or both in
  /// either order, with an optional `at` between.
  ///
  /// A day with no time is at `defaultHour`. A time with no day is today, or
  /// tomorrow once that time has passed; a weekday whose time has passed
  /// today is next week's. Nil for anything else.
  public static func dateTime(
    from text: String, now: Date = .now, calendar: Calendar = .current, defaultHour: Int = 9
  ) -> Date? {
    var day: Date?
    var time: (hour: Int, minute: Int)?
    var namedWeekday = false
    let words = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    for raw in words where raw != "at" {
      let word = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
      if time == nil, let parsed = TaskCaptureToken.timeOfDay(word) {
        time = parsed
      } else if day == nil, let parsed = TaskCaptureToken.due(word, now: now, calendar: calendar) {
        day = parsed
        namedWeekday = TaskCaptureToken.isWeekday(word)
      } else {
        return nil
      }
    }
    guard day != nil || time != nil else { return nil }
    let start = day ?? calendar.startOfDay(for: now)
    let clock = time ?? (defaultHour, 0)
    guard var result = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: start)
    else { return nil }
    if result <= now, time != nil, day == nil || namedWeekday {
      let step = day == nil ? 1 : 7
      result = calendar.date(byAdding: .day, value: step, to: result) ?? result
    }
    return result
  }

  static func dueLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
      calendar.isDate(date, inSameDayAs: tomorrow) {
      return "Tomorrow"
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_GB")
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    formatter.dateFormat = sameYear ? "EEE d MMM" : "d MMM yyyy"
    return formatter.string(from: date)
  }
}

/// One trailing word the add field understands.
enum TaskCaptureToken: Equatable {
  case estimate(Int)
  case due(Date)
  case tag(String)
  case priority(Int)

  /// The longest estimate a token may set. Anything past a day is a typo or
  /// not an estimate — `48h` is more likely a deadline than a sitting.
  static let maximumEstimateSeconds = 24 * 60 * 60

  init?(_ word: String, now: Date, calendar: Calendar) {
    let lower = word.lowercased()
    if let seconds = Self.estimate(lower) {
      self = .estimate(seconds)
    } else if lower.hasPrefix("@"), let date = Self.due(String(lower.dropFirst()), now: now, calendar: calendar) {
      self = .due(date)
    } else if let tag = Self.tag(word) {
      self = .tag(tag)
    } else if let value = Self.priority(lower) {
      self = .priority(value)
    } else {
      return nil
    }
  }

  /// `30m`, `90min`, `1h`, `1.5h`, `2hrs`, `1h30m`, `1h30`, each optionally
  /// after a `~`.
  static func estimate(_ word: String) -> Int? {
    let body = word.hasPrefix("~") ? String(word.dropFirst()) : word
    let pattern = #"^(?:(\d+(?:\.\d+)?)(h|hr|hrs|hour|hours)(?:(\d+)(m|min|mins)?)?|(\d+)(m|min|mins|minute|minutes))$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))
    else { return nil }
    func group(_ index: Int) -> String? {
      Range(match.range(at: index), in: body).map { String(body[$0]) }
    }
    let minutes: Double
    if let hours = group(1).flatMap(Double.init) {
      // `1.5h30` is not something anyone means; a fractional hour stands alone.
      let extra = group(3).flatMap(Double.init) ?? 0
      if extra > 0 && hours.rounded() != hours { return nil }
      guard extra < 60 else { return nil }
      minutes = hours * 60 + extra
    } else if let whole = group(5).flatMap(Double.init) {
      minutes = whole
    } else {
      return nil
    }
    let seconds = Int((minutes * 60).rounded())
    guard seconds > 0, seconds <= maximumEstimateSeconds else { return nil }
    return seconds
  }

  /// `today`, `tomorrow`, a weekday (the next one, today included), `3d` or
  /// `2w` from today, or a `yyyy-mm-dd` date. The start of that day.
  static func due(_ word: String, now: Date, calendar: Calendar) -> Date? {
    let today = calendar.startOfDay(for: now)
    func days(_ count: Int) -> Date? { calendar.date(byAdding: .day, value: count, to: today) }

    switch word {
    case "today", "tod": return today
    case "tomorrow", "tmr", "tom": return days(1)
    default: break
    }
    if let weekday = weekdays.first(where: { $0.names.contains(word) })?.number {
      let current = calendar.component(.weekday, from: today)
      return days((weekday - current + 7) % 7)
    }
    if let match = word.wholeMatch(of: /(\d{1,3})([dw])/), let count = Int(match.1), count > 0 {
      return days(match.2 == "w" ? count * 7 : count)
    }
    if let match = word.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
      let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) {
      let components = DateComponents(year: year, month: month, day: day)
      // Reject a date the calendar would roll over (`2026-02-31`) rather than
      // quietly filing the task in March.
      guard let date = calendar.date(from: components),
        calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day
      else { return nil }
      return calendar.startOfDay(for: date)
    }
    return nil
  }

  /// `9am`, `9:30pm`, `12am`, `14:00`, `9.30`, `noon`, `midnight` — an hour
  /// and minute on the 24-hour clock.
  static func timeOfDay(_ word: String) -> (hour: Int, minute: Int)? {
    switch word {
    case "noon", "midday": return (12, 0)
    case "midnight": return (0, 0)
    default: break
    }
    if let match = word.wholeMatch(of: /(\d{1,2})(?:[:.](\d{2}))?(am|pm|a|p)/),
      let hour = Int(match.1), (1...12).contains(hour) {
      let minute = match.2.flatMap { Int($0) } ?? 0
      guard minute < 60 else { return nil }
      let isPM = match.3.hasPrefix("p")
      return ((hour % 12) + (isPM ? 12 : 0), minute)
    }
    if let match = word.wholeMatch(of: /(\d{1,2})[:.](\d{2})/),
      let hour = Int(match.1), let minute = Int(match.2), hour < 24, minute < 60 {
      return (hour, minute)
    }
    return nil
  }

  static func isWeekday(_ word: String) -> Bool {
    weekdays.contains { $0.names.contains(word) }
  }

  /// `#word`, where the word starts with a letter — so `#1` and `#123`, which
  /// are issue numbers and list positions, stay in the title.
  static func tag(_ word: String) -> String? {
    guard word.count > 1, word.hasPrefix("#") else { return nil }
    let body = String(word.dropFirst())
    guard body.wholeMatch(of: /\p{L}[\p{L}\p{N}_\-\/]*/) != nil else { return nil }
    return body
  }

  /// `!1` to `!4`.
  static func priority(_ word: String) -> Int? {
    guard word.count == 2, word.hasPrefix("!"), let value = Int(word.dropFirst()),
      (1...4).contains(value)
    else { return nil }
    return value
  }

  /// Calendar weekday numbers: Sunday is 1.
  private static let weekdays: [(number: Int, names: Set<String>)] = [
    (1, ["sun", "sunday"]), (2, ["mon", "monday"]), (3, ["tue", "tues", "tuesday"]),
    (4, ["wed", "wednesday"]), (5, ["thu", "thur", "thurs", "thursday"]), (6, ["fri", "friday"]),
    (7, ["sat", "saturday"]),
  ]
}
