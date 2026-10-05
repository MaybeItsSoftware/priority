import Foundation

public struct TimerElapsedReassignmentPolicy {
  public static func remapElapsed(
    previousNodes: [TimerNode],
    latestOpenTaskIDs: Set<Int>,
    elapsedByTaskID: [Int: TimeInterval]
  ) -> [Int: TimeInterval] {
    guard !elapsedByTaskID.isEmpty else { return [:] }

    var parentByTaskID: [Int: Int] = [:]
    for node in previousNodes {
      if let parentID = node.parentId, parentID != 0 {
        parentByTaskID[node.id] = parentID
      }
    }

    var reassigned = elapsedByTaskID
    let removedTaskIDs = Set(elapsedByTaskID.keys).subtracting(latestOpenTaskIDs)

    for removedTaskID in removedTaskIDs {
      guard let elapsed = reassigned[removedTaskID], elapsed > 0 else { continue }

      var nextAncestorID = parentByTaskID[removedTaskID]
      while let ancestorID = nextAncestorID {
        if latestOpenTaskIDs.contains(ancestorID) {
          reassigned[ancestorID, default: 0] += elapsed
          break
        }
        nextAncestorID = parentByTaskID[ancestorID]
      }
    }

    return reassigned.filter { latestOpenTaskIDs.contains($0.key) }
  }
}
