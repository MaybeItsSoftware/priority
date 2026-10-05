import Foundation

public struct AuthRetryState: Equatable, Sendable {
  public var hasRetriedAfterUnauthorized: Bool

  public init(hasRetriedAfterUnauthorized: Bool = false) {
    self.hasRetriedAfterUnauthorized = hasRetriedAfterUnauthorized
  }
}

public enum AuthRetryDecision: Equatable, Sendable {
  case retryAuthentication
  case giveUp
}

public enum AuthRetryPolicy {
  public static func decisionForUnauthorized(state: AuthRetryState) -> (
    decision: AuthRetryDecision, nextState: AuthRetryState
  ) {
    guard !state.hasRetriedAfterUnauthorized else {
      return (.giveUp, state)
    }
    var next = state
    next.hasRetriedAfterUnauthorized = true
    return (.retryAuthentication, next)
  }
}
