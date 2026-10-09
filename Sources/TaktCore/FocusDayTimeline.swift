import Foundation

/// Placing a day's focus blocks on a clock.
///
/// The stored record of a block is "this much active time, logged at this
/// moment". Drawing it against an hour ruler means turning that back into a
/// span — it ran from `endedAt - seconds` to `endedAt` — which is honest about
/// where the work sat in the day but not about pauses: a block paused for
/// lunch reads as one long bar. The screen says so; this type just does the
/// arithmetic.
///
/// Pure on purpose. The view supplies hours and points, this supplies minutes
/// and lanes, and the awkward parts — a block that began before midnight, two
/// blocks that overlap because one was logged late — are testable without a
/// window.
public enum FocusDayTimeline {
  /// One block of work, as the timeline needs it. Deliberately not the stored
  /// record: `TaktCore` cannot see the database's types, and the live
  /// block has no stored record at all.
  public struct Block: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Active seconds credited to the block. Never negative.
    public let seconds: Int
    /// When the block was logged, which is when the work stopped.
    public let endedAt: Date
    /// The block currently running, drawn differently and always last.
    public let isLive: Bool

    public init(id: String, title: String, seconds: Int, endedAt: Date, isLive: Bool = false) {
      self.id = id
      self.title = title
      self.seconds = max(0, seconds)
      self.endedAt = endedAt
      self.isLive = isLive
    }
  }

  /// A block given a position: how far down the window it starts, how long it
  /// runs, and which of the side-by-side lanes it was given.
  public struct Placement: Identifiable, Equatable, Sendable {
    public let block: Block
    /// Minutes from the start of the window to the start of the block.
    public let offsetMinutes: Double
    /// The block's own length in minutes, after clamping to the day.
    public let minutes: Double
    /// Which column this block draws in, counting from the left.
    public let lane: Int

    public var id: String { block.id }
    public var startedAt: Date { block.endedAt.addingTimeInterval(-60 * minutes) }
    public var endedAt: Date { block.endedAt }
  }

  /// The window the day is drawn through, and what sits in it.
  public struct Layout: Equatable, Sendable {
    /// The hour the ruler starts at, and the hour it ends at — both on the
    /// hour, so every label lands on a rule.
    public let start: Date
    public let end: Date
    public let placements: [Placement]
    /// How many lanes the widest overlap needed; at least one, so a view can
    /// divide by it without checking.
    public let laneCount: Int

    public var hourCount: Int { max(1, Int((end.timeIntervalSince(start) / 3600).rounded())) }
    /// The hour marks, `hourCount + 1` of them: one per rule, including the
    /// closing one at the foot.
    public var hours: [Date] {
      (0...hourCount).map { start.addingTimeInterval(TimeInterval($0) * 3600) }
    }
  }

  /// One task's share of the day: the breakdown under the chart, and the rows
  /// the timeline's cursor walks.
  public struct TaskSummary: Identifiable, Equatable, Sendable {
    /// The task's key — its id where the block names one, else its title.
    public let id: String
    public let title: String
    public let seconds: Int
    public let blocks: Int

    public init(id: String, title: String, seconds: Int, blocks: Int) {
      self.id = id
      self.title = title
      self.seconds = seconds
      self.blocks = blocks
    }
  }

  /// The day's blocks gathered by task, most time first, ties by key so the
  /// order does not shuffle between renders. `taskKeys` maps a block id to
  /// the task it was spent on; a block without one stands for its own title.
  /// A task's title is its latest block's, since a rename happens between
  /// blocks rather than during one.
  public static func summaries(of blocks: [Block], taskKeys: [String: String]) -> [TaskSummary] {
    Dictionary(grouping: blocks) { taskKeys[$0.id] ?? $0.title }
      .map { key, values in
        TaskSummary(
          id: key, title: values.last?.title ?? "Deleted task",
          seconds: values.reduce(0) { $0 + $1.seconds }, blocks: values.count)
      }
      .sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
  }

  /// The narrowest the ruler gets. An afternoon with one 20-minute block in it
  /// should still read as an afternoon, not as a bar filling the pane.
  public static let minimumHours = 5
  /// What a day with nothing in it shows, so the empty state still has a shape.
  public static let defaultWindow = (startHour: 9, endHour: 18)

  /// Lays out one day.
  ///
  /// `day` is any moment inside the day being drawn; blocks are clamped to it,
  /// so a block that ran through midnight contributes only the part that
  /// belongs to this day and the rest is drawn on the day before.
  public static func layout(
    blocks: [Block],
    day: Date,
    calendar: Calendar = .current
  ) -> Layout {
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)

    // Spans first, in clock order. A zero-length block has no position worth
    // arguing about and is dropped rather than drawn as a hairline.
    var spans: [(block: Block, start: Date, end: Date)] = []
    for block in blocks where block.seconds > 0 {
      let end = min(max(block.endedAt, dayStart), dayEnd)
      let start = max(end.addingTimeInterval(-Double(block.seconds)), dayStart)
      guard end > start else { continue }
      spans.append((block, start, end))
    }
    spans.sort { $0.start == $1.start ? $0.block.id < $1.block.id : $0.start < $1.start }

    let window = self.window(for: spans.map { ($0.start, $0.end) }, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)

    // Greedy lanes: a block takes the leftmost column free at the moment it
    // starts. Overlaps are the exception — they happen when a block is logged
    // late — so the common day comes out one lane wide.
    var laneEnds: [Date] = []
    var placements: [Placement] = []
    for span in spans {
      let lane = laneEnds.firstIndex { $0 <= span.start } ?? laneEnds.count
      if lane == laneEnds.count { laneEnds.append(span.end) } else { laneEnds[lane] = span.end }
      placements.append(
        Placement(
          block: span.block,
          offsetMinutes: span.start.timeIntervalSince(window.start) / 60,
          minutes: span.end.timeIntervalSince(span.start) / 60,
          lane: lane))
    }

    return Layout(start: window.start, end: window.end, placements: placements, laneCount: max(1, laneEnds.count))
  }

  /// The hour-aligned window that holds every span, widened to `minimumHours`
  /// and then pushed back inside the day rather than allowed to overhang it.
  private static func window(
    for spans: [(start: Date, end: Date)],
    dayStart: Date,
    dayEnd: Date,
    calendar: Calendar
  ) -> (start: Date, end: Date) {
    guard let earliest = spans.map(\.start).min(), let latest = spans.map(\.end).max() else {
      let start = calendar.date(byAdding: .hour, value: defaultWindow.startHour, to: dayStart) ?? dayStart
      let end = calendar.date(byAdding: .hour, value: defaultWindow.endHour, to: dayStart) ?? dayEnd
      return (start, end)
    }
    var start = floorToHour(earliest, dayStart: dayStart)
    var end = ceilToHour(latest, dayStart: dayStart)
    let minimum = TimeInterval(minimumHours) * 3600
    if end.timeIntervalSince(start) < minimum {
      end = start.addingTimeInterval(minimum)
      if end > dayEnd {
        end = dayEnd
        start = max(dayStart, end.addingTimeInterval(-minimum))
      }
    }
    return (start, end)
  }

  private static func floorToHour(_ date: Date, dayStart: Date) -> Date {
    let hours = (date.timeIntervalSince(dayStart) / 3600).rounded(.down)
    return dayStart.addingTimeInterval(max(0, hours) * 3600)
  }

  private static func ceilToHour(_ date: Date, dayStart: Date) -> Date {
    let hours = (date.timeIntervalSince(dayStart) / 3600).rounded(.up)
    return dayStart.addingTimeInterval(max(1, hours) * 3600)
  }
}
