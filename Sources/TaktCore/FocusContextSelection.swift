import Foundation

/// What "available now" means as a set of condition ids, worked out without
/// the app: turning one on or off, and what a saved context is worth on the
/// next launch.
///
/// The phones do the same in their focus models (`FocusModel.toggleCondition`
/// on iOS, `FocusViewModel.toggleCondition` on Android); this is the Mac's
/// copy, kept here so the rule is tested rather than read off a view.
public enum FocusContextSelection {
  /// The set with `conditionID` flipped. You are in one place at a time, so
  /// turning a location on turns every other location off; capabilities
  /// ("Floor space", "Quiet") combine freely.
  public static func toggling(
    _ conditionID: String, isLocation: Bool, in current: Set<String>, locationIDs: Set<String>
  ) -> Set<String> {
    if current.contains(conditionID) { return current.subtracting([conditionID]) }
    var next = current
    if isLocation { next.subtract(locationIDs) }
    next.insert(conditionID)
    return next
  }

  /// A saved context, less any condition that no longer exists. Archived ones
  /// stay: archiving hides a condition from new requirements, not from tasks
  /// that already need it.
  public static func restoring(_ saved: [String], known: Set<String>) -> Set<String> {
    Set(saved).intersection(known)
  }

  /// The context in a few words, for a status bar: the names in the order the
  /// conditions are listed, or `nil` with nothing on.
  public static func summary(_ active: Set<String>, names: [(id: String, name: String)]) -> String? {
    let on = names.filter { active.contains($0.id) }.map(\.name)
    return on.isEmpty ? nil : on.joined(separator: " · ")
  }
}
