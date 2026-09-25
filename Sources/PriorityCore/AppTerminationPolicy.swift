import Foundation

public enum AppTerminationDecision: Equatable {
  case terminateNow
  /// Put the windows away and stay alive as a status item.
  case dismissToMenuBar
  case cancel
}

public enum AppTerminationPolicy {
  /// Whether a termination request should be honoured.
  ///
  /// Only the app's own status item menu can really quit it. Everything else
  /// is treated as "I am done looking at this", because the menu bar is a
  /// standing reminder of what is on today and a reminder you can close by
  /// pressing ⌘Q is not a reminder.
  ///
  /// The two ways of not quitting differ in whether there is anything to put
  /// away. Windowed, ⌘Q closes the windows and drops the app to its status
  /// item — visibly *something*, so the shortcut doesn't look broken. As an
  /// agent there is nothing on screen to dismiss, so the request is simply
  /// cancelled; that case is the system asking on behalf of something the user
  /// did not do.
  public static func decision(
    explicitQuitRequested: Bool,
    isRegularActivationPolicy: Bool
  ) -> AppTerminationDecision {
    if explicitQuitRequested { return .terminateNow }
    return isRegularActivationPolicy ? .dismissToMenuBar : .cancel
  }
}
