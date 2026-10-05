import Foundation

struct ListScopedTaskIDStore {
  static let offlineScopeKey = "__offline__"

  private let defaults: UserDefaults
  private let defaultsKey: String
  private let maximumCount: Int?

  init(defaultsKey: String, maximumCount: Int? = nil, defaults: UserDefaults = .standard) {
    self.defaultsKey = defaultsKey
    self.maximumCount = maximumCount
    self.defaults = defaults
  }

  func load(for listId: String) -> [Int] {
    let scope = Self.scope(for: listId)
    let allQueues = allQueuesFromDefaults()
    return normalizedQueue(allQueues[scope] ?? [])
  }

  func save(_ queue: [Int], for listId: String) {
    let scope = Self.scope(for: listId)
    var allQueues = allQueuesFromDefaults()
    let normalized = normalizedQueue(queue)
    if normalized.isEmpty {
      allQueues.removeValue(forKey: scope)
    } else {
      allQueues[scope] = normalized
    }
    defaults.set(allQueues, forKey: defaultsKey)
  }

  private static func scope(for listId: String) -> String {
    listId.isEmpty ? offlineScopeKey : listId
  }

  private func allQueuesFromDefaults() -> [String: [Int]] {
    guard let raw = defaults.dictionary(forKey: defaultsKey) else { return [:] }

    var parsed: [String: [Int]] = [:]
    for (listId, value) in raw {
      if let queue = value as? [Int] {
        parsed[listId] = normalizedQueue(queue)
      } else if let queue = value as? [NSNumber] {
        parsed[listId] = normalizedQueue(queue.map(\.intValue))
      }
    }
    return parsed
  }

  private func normalizedQueue(_ queue: [Int]) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []

    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }

    if let maximumCount, normalized.count > maximumCount {
      return Array(normalized.prefix(maximumCount))
    }

    return normalized
  }
}
