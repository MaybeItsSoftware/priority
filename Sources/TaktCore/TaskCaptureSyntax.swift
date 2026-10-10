import Foundation
import TaktRustCore

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
///
/// The reading is the Rust core's (`core/src/capture.rs`), which Android calls
/// too; this keeps TaktCore's types so the add fields did not change. One call
/// per keystroke crosses the boundary, never one per word.
public struct TaskCapture: Equatable, Sendable {
  public var title: String
  public var estimateSeconds: Int?
  /// The start of the day it is due, the same instant the `Due today` and
  /// `Due tomorrow` commands write.
  public var dueAt: Date?
  public var tags: [String]
  /// 1 to 4, the range the workspace stores.
  public var priority: Int?
  /// Who it waits on, from `wait:Sam`: the task is filed in Waiting on with
  /// that tag, as `ww` would put it there.
  public var waitingOn: String?

  public init(
    title: String, estimateSeconds: Int? = nil, dueAt: Date? = nil, tags: [String] = [],
    priority: Int? = nil, waitingOn: String? = nil
  ) {
    self.title = title
    self.estimateSeconds = estimateSeconds
    self.dueAt = dueAt
    self.tags = tags
    self.priority = priority
    self.waitingOn = waitingOn
  }

  /// Whether anything beyond the title was found.
  public var hasDetails: Bool {
    estimateSeconds != nil || dueAt != nil || !tags.isEmpty || priority != nil || waitingOn != nil
  }

  /// Parses `text` as typed into an add field. See the type for the rules.
  public static func parse(
    _ text: String, now: Date = .now, calendar: Calendar = .current
  ) -> TaskCapture {
    TaskCapture(
      captureParse(text: text, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier))
  }

  /// Short labels for what was found, in the order the field shows them:
  /// `45m`, `Fri 3 Oct`, `#work`, `!1`.
  public func detailLabels(now: Date = .now, calendar: Calendar = .current) -> [String] {
    captureDetailLabels(capture: core, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier)
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
    captureDateTime(
      text: text, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier,
      defaultHour: Int64(defaultHour)
    ).map { Date(rankingMilliseconds: $0) }
  }

  init(_ core: CaptureParts) {
    self.init(
      title: core.title, estimateSeconds: core.estimateSeconds.map { Int($0) },
      dueAt: core.dueAtMs.map { Date(rankingMilliseconds: $0) }, tags: core.tags,
      priority: core.priority.map { Int($0) }, waitingOn: core.waitingOn)
  }

  var core: CaptureParts {
    CaptureParts(
      title: title, estimateSeconds: estimateSeconds.map { Int64($0) }, dueAtMs: dueAt?.rankingMilliseconds,
      tags: tags, priority: priority.map { Int64($0) }, waitingOn: waitingOn)
  }
}

/// The single words the add field understands, for the readers that share
/// them (`HabitPolicy`'s quick entry).
enum TaskCaptureToken {
  /// The longest estimate a token may set. Anything past a day is a typo or
  /// not an estimate — `48h` is more likely a deadline than a sitting.
  static let maximumEstimateSeconds = 24 * 60 * 60

  /// `30m`, `90min`, `1h`, `1.5h`, `2hrs`, `1h30m`, `1h30`, each optionally
  /// after a `~`.
  static func estimate(_ word: String) -> Int? {
    captureEstimate(word: word).map { Int($0) }
  }

  /// `today`, `tomorrow`, a weekday (the next one, today included), `3d` or
  /// `2w` from today, or a `yyyy-mm-dd` date. The start of that day.
  static func due(_ word: String, now: Date, calendar: Calendar) -> Date? {
    captureDue(word: word, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier)
      .map { Date(rankingMilliseconds: $0) }
  }
}
