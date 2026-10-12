import Foundation

/// Ticking a condition on or off in a task's requirements, as the conditions
/// picker (`cc`) does: one condition at a time, without having to think about
/// the groups the requirements are stored as.
///
/// Requirements are groups: every group must hold, and any one condition in a
/// group satisfies it. A tick is a group of its own — "and needs Floor space"
/// — except for a place: you are in one place at a time, so a second place
/// joins the group the first is in ("Home or Campus") rather than asking for
/// both, which nothing could ever satisfy.
public enum TaskRequirementToggle {
  /// Whether `id` is required by any group.
  public static func requires(_ id: String, in groups: [[String]]?) -> Bool {
    (groups ?? []).contains { $0.contains(id) }
  }

  /// `groups` with `id` ticked on, or off if it was already required.
  /// Ticking off takes it out of every group and drops a group it leaves
  /// empty. `places` are the ids of the conditions that are places. Nil when
  /// nothing is left.
  public static func toggling(_ id: String, in groups: [[String]]?, places: Set<String>) -> [[String]]? {
    var groups = groups ?? []
    if requires(id, in: groups) {
      groups = groups.map { $0.filter { $0 != id } }.filter { !$0.isEmpty }
    } else if places.contains(id),
      let index = groups.firstIndex(where: { group in group.allSatisfy { places.contains($0) } }) {
      groups[index].append(id)
    } else {
      groups.append([id])
    }
    return groups.isEmpty ? nil : groups
  }
}
