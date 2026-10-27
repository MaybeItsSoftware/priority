import Foundation

/// A local notification posted for focus block and break events.
public struct FocusNotification: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case blockFinished(taskTitle: String?)
    case breakFinished(taskTitle: String?)
  }

  public let id: String
  public let kind: Kind
  public let title: String
  public let subtitle: String?
  public let body: String
  public let playSound: Bool

  public init(kind: Kind, playSound: Bool = true) {
    self.kind = kind
    self.playSound = playSound
    switch kind {
    case .blockFinished(let taskTitle):
      self.id = "focus-block-finished"
      self.title = "Focus block finished"
      self.subtitle = taskTitle
      self.body = "Take a break or review the block."
    case .breakFinished(let taskTitle):
      self.id = "focus-break-finished"
      self.title = "Break ended"
      self.subtitle = taskTitle
      self.body = "Ready to resume focus or pick your next task."
    }
  }
}

/// Decides when notifications should be dispatched and builds their content.
public enum FocusNotificationPolicy {
  /// Whether a running focus block has elapsed its work duration.
  public static func isBlockFinished(elapsedSeconds: Int, workDurationSeconds: Int) -> Bool {
    elapsedSeconds >= workDurationSeconds
  }

  /// Whether a break timer has expired.
  public static func isBreakFinished(breakEndsAt: Date?, now: Date) -> Bool {
    guard let breakEndsAt else { return false }
    return breakEndsAt <= now
  }

  /// Builds a notification for a finished block if enabled.
  public static func blockFinishedNotification(
    taskTitle: String?,
    enabled: Bool,
    playSound: Bool
  ) -> FocusNotification? {
    guard enabled else { return nil }
    return FocusNotification(kind: .blockFinished(taskTitle: taskTitle), playSound: playSound)
  }

  /// Builds a notification for an ended break if enabled.
  public static func breakFinishedNotification(
    taskTitle: String?,
    enabled: Bool,
    playSound: Bool
  ) -> FocusNotification? {
    guard enabled else { return nil }
    return FocusNotification(kind: .breakFinished(taskTitle: taskTitle), playSound: playSound)
  }
}
