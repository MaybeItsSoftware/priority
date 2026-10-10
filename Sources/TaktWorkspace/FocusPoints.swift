import Foundation
import TaktRustCore

/// Scoring a block of focused work.
///
/// A block is worth the minutes it took, multiplied by how well it went. The
/// time is the database's to know; the multiplier is the user's own judgement,
/// given when they finish. Minutes and points are both carried to one decimal
/// place, so a twelve-and-a-half minute block is worth 12.5 rather than 12 —
/// rounding down would quietly punish short sittings.
public enum FocusPoints {
  /// The widest multiplier the app will store. A slider of presets sits well
  /// inside it; the bound exists so a typed-in number cannot make one block
  /// outweigh a month of work.
  public static let multiplierRange: ClosedRange<Double> = 0...5

  /// The Rust core's `progress::focus_minutes`, which the core's own
  /// `finish_block` scores with, so the prompt's preview and the stored award
  /// cannot disagree.
  public static func minutes(seconds: Int) -> Double {
    focusMinutes(seconds: Int64(seconds))
  }

  /// Clamps a multiplier into range, and treats a nonsense one as ordinary
  /// work rather than rejecting the block and losing the time with it.
  /// The Rust core's `progress::clamped_focus_multiplier`.
  public static func clamped(multiplier: Double) -> Double {
    clampedFocusMultiplier(multiplier: multiplier)
  }

  /// The Rust core's `progress::focus_score`.
  public static func score(seconds: Int, multiplier: Double) -> Double {
    focusScore(seconds: Int64(seconds), multiplier: multiplier)
  }

  /// The house format for a score: one decimal place, and no trailing `.0` on
  /// a whole number, so a column of them stays readable.
  public static func formatted(_ points: Double) -> String {
    let rounded = oneDecimalPlace(points)
    return rounded == rounded.rounded()
      ? String(format: "%.0f", rounded)
      : String(format: "%.1f", rounded)
  }

  private static func oneDecimalPlace(_ value: Double) -> Double {
    (value * 10).rounded() / 10
  }
}

/// The multipliers offered as presets when a block ends.
///
/// Named for the sitting rather than for a grade: "how did that go" is a
/// question someone can answer honestly in the second after finishing, where
/// "rate this 1–5" invites them to say 4 every time.
public enum FocusQuality: String, Codable, CaseIterable, Identifiable, Sendable {
  case scattered
  case passable
  case solid
  case sharp
  case flow

  public var id: String { rawValue }

  public var multiplier: Double {
    switch self {
    case .scattered: return 0.5
    case .passable: return 0.75
    case .solid: return 1
    case .sharp: return 1.5
    case .flow: return 2
    }
  }

  public var title: String {
    switch self {
    case .scattered: return "Scattered"
    case .passable: return "Passable"
    case .solid: return "Solid"
    case .sharp: return "Sharp"
    case .flow: return "Flow"
    }
  }

  public var detail: String {
    switch self {
    case .scattered: return "Kept losing the thread"
    case .passable: return "Got there, slowly"
    case .solid: return "An honest block of work"
    case .sharp: return "Quick and clean"
    case .flow: return "Lost track of the time"
    }
  }

  /// The preset a multiplier corresponds to, or nil when it was typed in.
  public static func matching(multiplier: Double) -> FocusQuality? {
    allCases.first { $0.multiplier == multiplier }
  }
}

/// Points earned by one finished focus block.
///
/// The task's title is copied in rather than looked up. A score is a record of
/// something that happened: renaming the task afterwards, or deleting it,
/// should not rewrite or erase what was earned for it.
public struct FocusAward: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public let sessionId: String?
  public let taskId: String?
  public let taskTitle: String
  public let seconds: Int
  public let minutes: Double
  public let multiplier: Double
  public let points: Double
  public let awardedAt: Date

  public var quality: FocusQuality? { FocusQuality.matching(multiplier: multiplier) }

  public init(
    id: String = UUID().uuidString,
    sessionId: String?,
    taskId: String?,
    taskTitle: String,
    seconds: Int,
    multiplier: Double,
    awardedAt: Date
  ) {
    self.id = id
    self.sessionId = sessionId
    self.taskId = taskId
    self.taskTitle = taskTitle
    self.seconds = max(0, seconds)
    self.minutes = FocusPoints.minutes(seconds: seconds)
    self.multiplier = FocusPoints.clamped(multiplier: multiplier)
    self.points = FocusPoints.score(seconds: seconds, multiplier: multiplier)
    self.awardedAt = awardedAt
  }
}

/// What the running totals come to. Held together so the UI reads one value
/// rather than issuing three queries that could disagree with each other.
public struct FocusPointsSummary: Sendable, Equatable {
  public let today: Double
  public let last7Days: Double
  public let allTime: Double
  public let blocksToday: Int

  public static let zero = FocusPointsSummary(today: 0, last7Days: 0, allTime: 0, blocksToday: 0)

  public init(today: Double, last7Days: Double, allTime: Double, blocksToday: Int) {
    self.today = today
    self.last7Days = last7Days
    self.allTime = allTime
    self.blocksToday = blocksToday
  }
}
