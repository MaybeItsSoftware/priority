import Foundation
import TaktRustCore

/// One member of a requirement group, read: the condition it names, and
/// whether it asks for that condition *not* to hold ("!home", shown as "not
/// Home"). The reading is the Rust core's (`conditions/requirement.rs`), so
/// every client and the ranking agree on what "!" means.
public struct TaskRequirement: Hashable, Sendable {
  public let conditionID: String
  public let isNegated: Bool

  public init(conditionID: String, isNegated: Bool) {
    self.conditionID = conditionID
    self.isNegated = isNegated
  }

  /// A member as stored.
  public init(_ member: String) {
    self.init(conditionID: requirementConditionId(member: member), isNegated: requirementIsNegated(member: member))
  }

  /// The member as stored.
  public var member: String { requirementMember(conditionId: conditionID, negated: isNegated) }

  /// Whether it is met while `available` hold.
  public func isMet(available: Set<String>) -> Bool { Self.isMet(group: [member], available: available) }

  /// "Home", or "not Home".
  public func label(name: String) -> String { isNegated ? "not \(name)" : name }

  /// A member written out: its condition's name from `name` (or `missing`
  /// when there is none), "not " before it when negated.
  public static func label(_ member: String, missing: String = "Missing condition", name: (String) -> String?) -> String {
    let requirement = TaskRequirement(member)
    return requirement.label(name: name(requirement.conditionID) ?? missing)
  }

  /// A group written out: "Campus or not Quiet".
  public static func label(group: [String], missing: String = "Missing condition", name: (String) -> String?) -> String {
    group.map { label($0, missing: missing, name: name) }.joined(separator: " or ")
  }

  /// Whether any member of `group` is met while `available` hold.
  public static func isMet(group: [String], available: Set<String>) -> Bool {
    requirementGroupIsMet(group: group, heldIds: Array(available))
  }
}
