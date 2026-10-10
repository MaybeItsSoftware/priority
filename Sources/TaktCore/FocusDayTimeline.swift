import Foundation
import TaktRustCore

/// Placing a day's focus blocks on a clock.
///
/// The stored record of a block is "this much active time, logged at this
/// moment". Drawing it against an hour ruler means turning that back into a
/// span — it ran from `endedAt - seconds` to `endedAt` — which is honest about
/// where the work sat in the day but not about pauses: a block paused for
/// lunch reads as one long bar. The screen says so; this type just does the
/// arithmetic.
///
/// The arithmetic is the Rust core's `progress::focus_day_layout` and
/// `focus_day_summaries`, which hand back indices into the blocks given, so
/// a title never crosses back. The view supplies hours and points; the core
/// supplies minutes and lanes, and the awkward parts (a block that began
/// before midnight, two blocks that overlap because one was logged late).
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
    focusDaySummaries(
      entries: blocks.map { FocusTimelineEntry(key: taskKeys[$0.id] ?? $0.title, seconds: Int64($0.seconds)) }
    ).map { summary in
      TaskSummary(
        id: summary.key, title: blocks[Int(summary.latest)].title, seconds: Int(summary.seconds),
        blocks: Int(summary.blocks))
    }
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
    let layout = focusDayLayout(
      blocks: blocks.map {
        TimelineBlock(id: $0.id, seconds: Int64($0.seconds), endedAtMs: $0.endedAt.rankingMilliseconds)
      },
      dayMs: day.rankingMilliseconds, zone: calendar.timeZone.identifier)
    return Layout(
      start: Date(rankingMilliseconds: layout.startMs),
      end: Date(rankingMilliseconds: layout.endMs),
      placements: layout.placements.map {
        Placement(
          block: blocks[Int($0.block)], offsetMinutes: $0.offsetMinutes, minutes: $0.minutes, lane: Int($0.lane))
      },
      laneCount: Int(layout.laneCount))
  }
}
