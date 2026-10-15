import Foundation

/// What `←`/`→` and typing do to the Conditions tab's "Available now" rows:
/// step where you are, the time you have and when it expires, and read a
/// time typed in. Pure, so the steps are tested without the app.
public enum ConditionsPaneSteps {
  /// The place `by` steps from `current` along `places`, with nowhere in
  /// particular (nil) before the first. Stops at either end rather than
  /// wrapping, so holding a key cannot run past where you meant.
  public static func place(from current: String?, in places: [String], by step: Int) -> String? {
    let stops: [String?] = [nil] + places
    let index = stops.firstIndex(of: current) ?? 0
    return stops[min(max(index + step, 0), stops.count - 1)]
  }

  /// A quarter of an hour, the time row's step.
  public static let timeStepMinutes = 15
  /// The most the time row steps up to: a long day.
  public static let maximumMinutes = 12 * 60

  /// The minutes left `by` steps of a quarter of an hour from what is left
  /// now, nil being no limit, which sits below the first step. A time left
  /// between steps snaps to the step in the direction asked.
  public static func minutes(from current: Int?, by step: Int) -> Int? {
    guard step != 0 else { return current }
    let quarter = timeStepMinutes
    let left = current.map { max(0, $0) } ?? 0
    let snapped = step > 0 ? (left / quarter) * quarter : ((left + quarter - 1) / quarter) * quarter
    let next = min(max(snapped + step * quarter, 0), maximumMinutes)
    return next == 0 ? nil : next
  }

  /// When the context expires, as its stops: never, in one, two or four
  /// hours, or at the end of the day.
  public enum Expiry: Equatable, Sendable, CaseIterable {
    case never, oneHour, twoHours, fourHours, endOfDay

    /// When it expires if set at `now`.
    public func date(now: Date, calendar: Calendar = .current) -> Date? {
      switch self {
      case .never: nil
      case .oneHour: now.addingTimeInterval(3600)
      case .twoHours: now.addingTimeInterval(2 * 3600)
      case .fourHours: now.addingTimeInterval(4 * 3600)
      case .endOfDay: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
      }
    }

    /// The stop an expiry set earlier reads as: the first whose date is at
    /// or after it, so one set an hour ago for two hours reads as one hour.
    public static func nearest(to date: Date?, now: Date, calendar: Calendar = .current) -> Expiry {
      guard let date else { return .never }
      return allCases.dropFirst().first { ($0.date(now: now, calendar: calendar) ?? .distantFuture) >= date }
        ?? .endOfDay
    }

    /// The stop `by` steps along, stopping at either end.
    public func stepped(by step: Int) -> Expiry {
      let cases = Self.allCases
      let index = cases.firstIndex(of: self) ?? 0
      return cases[min(max(index + step, 0), cases.count - 1)]
    }
  }

  /// A time typed on the time row, as the moment it runs to: minutes
  /// (`45`), hours and minutes (`1h30`, `1h`, `90m`, `1.5h`), or a clock
  /// time today (`17:00`, `5pm`, `5:30pm`) — tomorrow if that has passed.
  /// Nil for anything else; an empty field is no limit, which the caller
  /// decides.
  public static func time(typed text: String, now: Date, calendar: Calendar = .current) -> Date? {
    let entry = text.lowercased().filter { !$0.isWhitespace }
    guard !entry.isEmpty else { return nil }
    if let minutes = duration(entry), minutes > 0 {
      return now.addingTimeInterval(Double(min(minutes, maximumMinutes)) * 60)
    }
    guard let (hour, minute) = clock(entry) else { return nil }
    var parts = calendar.dateComponents([.year, .month, .day], from: now)
    parts.hour = hour
    parts.minute = minute
    guard let today = calendar.date(from: parts) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
  }

  /// `45`, `90m`, `1h`, `1h30`, `1h30m`, `1.5h` as minutes.
  private static func duration(_ entry: String) -> Int? {
    if let minutes = Int(entry) { return minutes }
    if entry.hasSuffix("m"), !entry.contains("h"), let minutes = Int(entry.dropLast()) { return minutes }
    let halves = entry.split(separator: "h", maxSplits: 1, omittingEmptySubsequences: false)
    guard halves.count == 2, let hours = Double(halves[0]) else { return nil }
    let rest = halves[1].hasSuffix("m") ? halves[1].dropLast() : halves[1]
    let minutes = rest.isEmpty ? 0 : Int(rest)
    guard let minutes, hours >= 0 else { return nil }
    return Int((hours * 60).rounded()) + minutes
  }

  /// `17:00`, `5pm`, `5:30pm`, `12am` as an hour and minute of the day.
  private static func clock(_ entry: String) -> (Int, Int)? {
    var text = Substring(entry)
    var meridiem: String?
    for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
      meridiem = suffix
      text = text.dropLast(2)
    }
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(pieces.count), let hour = Int(pieces[0]) else { return nil }
    let minute = pieces.count == 2 ? Int(pieces[1]) : 0
    guard let minute, (0..<60).contains(minute), pieces.count == 2 || meridiem != nil else { return nil }
    switch meridiem {
    case "am"?: return (1...12).contains(hour) ? (hour % 12, minute) : nil
    case "pm"?: return (1...12).contains(hour) ? (hour % 12 + 12, minute) : nil
    default: return (0..<24).contains(hour) ? (hour, minute) : nil
    }
  }
}
