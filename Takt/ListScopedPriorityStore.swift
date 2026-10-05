import Foundation

/// Stores per-list, per-parent priority queues. The outer key is the Checkvist list id,
/// the inner key is the parent task id (0 = root), and the value is an ordered array of
/// task ids where index 0 corresponds to rank 1 within that parent scope. There is no
/// cap on the number of priorities per scope.
struct ListScopedPriorityStore {
  static let offlineScopeKey = "__offline__"

  private let defaults: UserDefaults
  private let defaultsKey: String

  init(defaultsKey: String, defaults: UserDefaults = .standard) {
    self.defaultsKey = defaultsKey
    self.defaults = defaults
  }

  func load(for listId: String) -> [Int: [Int]] {
    let scope = Self.scope(for: listId)
    let all = allFromDefaults()
    return all[scope] ?? [:]
  }

  func save(_ queues: [Int: [Int]], for listId: String) {
    let scope = Self.scope(for: listId)
    var all = allFromDefaults()
    let normalized = queues
      .mapValues { Self.normalizedQueue($0) }
      .filter { !$0.value.isEmpty }
    if normalized.isEmpty {
      all.removeValue(forKey: scope)
    } else {
      all[scope] = normalized
    }
    writeAll(all)
  }

  private static func scope(for listId: String) -> String {
    listId.isEmpty ? offlineScopeKey : listId
  }

  private func allFromDefaults() -> [String: [Int: [Int]]] {
    guard let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([String: [String: [Int]]].self, from: data)
    else { return [:] }
    var result: [String: [Int: [Int]]] = [:]
    for (listId, byParent) in decoded {
      var inner: [Int: [Int]] = [:]
      for (key, ids) in byParent {
        if let parentId = Int(key) {
          let norm = Self.normalizedQueue(ids)
          if !norm.isEmpty { inner[parentId] = norm }
        }
      }
      if !inner.isEmpty { result[listId] = inner }
    }
    return result
  }

  private func writeAll(_ all: [String: [Int: [Int]]]) {
    var encoded: [String: [String: [Int]]] = [:]
    for (listId, byParent) in all {
      var inner: [String: [Int]] = [:]
      for (parentId, ids) in byParent {
        inner[String(parentId)] = ids
      }
      encoded[listId] = inner
    }
    if let data = try? JSONEncoder().encode(encoded) {
      defaults.set(data, forKey: defaultsKey)
    }
  }

  static func normalizedQueue(_ queue: [Int]) -> [Int] {
    var seen = Set<Int>()
    var result: [Int] = []
    for id in queue where id > 0 && !seen.contains(id) {
      seen.insert(id)
      result.append(id)
    }
    return result
  }
}
