import Foundation

/// Ticking a condition on or off in a task's requirements, as the conditions
/// picker (`cc`) does: one condition at a time, without having to think about
/// the groups the requirements are stored as.
///
/// Requirements are groups: every group must hold, and any one condition in a
/// group satisfies it. A tick is a group of its own — "and needs Floor space"
/// — except for a place: you are in one place at a time, so a second place
/// joins the group the first is in ("Home or Campus") rather than asking for
/// both, which nothing could ever satisfy. A condition can also be ticked as
/// *not* holding (`!`: "not Home", stored "!home"); that is always a group of
/// its own, since "not Home" and "not Campus" are both wanted, not either.
public enum TaskRequirementToggle {
  /// Whether `id` is required by any group, either way.
  public static func requires(_ id: String, in groups: [[String]]?) -> Bool {
    requirement(of: id, in: groups) != nil
  }

  /// How `id` is first required — as itself, or negated — or nil when it is
  /// not.
  public static func requirement(of id: String, in groups: [[String]]?) -> TaskRequirement? {
    (groups ?? []).joined().lazy.map(TaskRequirement.init).first { $0.conditionID == id }
  }

  /// `groups` with `id` ticked on, or off if it was already required either
  /// way. Ticking off takes it out of every group and drops a group it
  /// leaves empty. `places` are the ids of the conditions that are places.
  /// Nil when nothing is left.
  public static func toggling(_ id: String, in groups: [[String]]?, places: Set<String>) -> [[String]]? {
    var groups = groups ?? []
    if requires(id, in: groups) {
      groups = removing(id, from: groups)
    } else if places.contains(id),
      let index = groups.firstIndex(where: { group in group.allSatisfy { places.contains($0) } }) {
      groups[index].append(id)
    } else {
      groups.append([id])
    }
    return groups.isEmpty ? nil : groups
  }

  /// `groups` with `id` ticked as not holding: required as itself it turns
  /// into "not", and already "not" it is ticked off. Nil when nothing is
  /// left.
  public static func negating(_ id: String, in groups: [[String]]?) -> [[String]]? {
    let wasNegated = requirement(of: id, in: groups)?.isNegated == true
    var groups = removing(id, from: groups ?? [])
    if !wasNegated { groups.append([TaskRequirement(conditionID: id, isNegated: true).member]) }
    return groups.isEmpty ? nil : groups
  }

  /// `groups` without any member naming `id`, either way, and without the
  /// groups that leaves empty.
  private static func removing(_ id: String, from groups: [[String]]) -> [[String]] {
    groups.map { $0.filter { TaskRequirement($0).conditionID != id } }.filter { !$0.isEmpty }
  }
}
