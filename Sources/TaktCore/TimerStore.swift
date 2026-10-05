import Foundation

public struct TimerNode: Equatable, Sendable {
  public let id: Int
  public let parentId: Int?

  public init(id: Int, parentId: Int?) {
    self.id = id
    self.parentId = parentId
  }
}

public enum TimerStore {
  public static func formatted(_ elapsed: TimeInterval) -> String {
    if elapsed < 60 {
      return "\(Int(elapsed))s"
    } else if elapsed < 3600 {
      let minutes = elapsed / 60
      return minutes < 10 ? String(format: "%.1fm", minutes) : "\(Int(minutes))m"
    } else {
      let hours = elapsed / 3600
      return hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours))h"
    }
  }

  public static func childCountByTaskId(nodes: [TimerNode]) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for node in nodes {
      let parentId = node.parentId ?? 0
      guard parentId != 0 else { continue }
      counts[parentId, default: 0] += 1
    }
    return counts
  }

  public static func rolledUpElapsedByTaskId(nodes: [TimerNode], ownElapsed: [Int: TimeInterval])
    -> [Int: TimeInterval]
  {
    var childrenByParent: [Int: [TimerNode]] = [:]
    for node in nodes {
      childrenByParent[node.parentId ?? 0, default: []].append(node)
    }

    var cache: [Int: TimeInterval] = [:]
    // Guards against a cycle in the parent chain, which makes a task its own
    // descendant and sent this into unbounded recursion — a hard crash, not a
    // wrong number. The memo alone does not help: it is only written once the
    // recursion returns, which on a cycle it never does. Tasks arrive from the
    // network, so the shape has to be tolerated rather than assumed away.
    var inProgress: Set<Int> = []
    func total(for id: Int) -> TimeInterval {
      if let cached = cache[id] { return cached }
      // Already being summed further up the stack; its time is counted there.
      guard inProgress.insert(id).inserted else { return 0 }
      defer { inProgress.remove(id) }

      var elapsed = ownElapsed[id] ?? 0
      for child in childrenByParent[id] ?? [] {
        elapsed += total(for: child.id)
      }
      cache[id] = elapsed
      return elapsed
    }

    for node in nodes {
      _ = total(for: node.id)
    }
    return cache
  }
}
