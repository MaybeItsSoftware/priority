import Foundation

struct EisenhowerLevel: Codable, Equatable, Sendable {
  var urgency: Double
  var importance: Double

  static let zero = EisenhowerLevel(urgency: 0, importance: 0)
}

/// Stores per-list urgency and importance levels for tasks.
/// The outer key is the Checkvist list id, the inner key is the Checkvist task id.
struct ListScopedEisenhowerStore {
  static let offlineScopeKey = "__offline__"

  private let defaults: UserDefaults
  private let defaultsKey: String

  init(defaultsKey: String, defaults: UserDefaults = .standard) {
    self.defaultsKey = defaultsKey
    self.defaults = defaults
  }

  func load(for listId: String) -> [Int: EisenhowerLevel] {
    let scope = Self.scope(for: listId)
    let all = allFromDefaults()
    return all[scope] ?? [:]
  }

  func save(_ levels: [Int: EisenhowerLevel], for listId: String) {
    let scope = Self.scope(for: listId)
    var all = allFromDefaults()
    let filtered = levels.filter { $0.value.urgency != 0 || $0.value.importance != 0 }
    if filtered.isEmpty {
      all.removeValue(forKey: scope)
    } else {
      all[scope] = filtered
    }
    writeAll(all)
  }

  private static func scope(for listId: String) -> String {
    listId.isEmpty ? offlineScopeKey : listId
  }

  private func allFromDefaults() -> [String: [Int: EisenhowerLevel]] {
    guard let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([String: [String: EisenhowerLevel]].self, from: data)
    else { return [:] }
    var result: [String: [Int: EisenhowerLevel]] = [:]
    for (listId, byTask) in decoded {
      var inner: [Int: EisenhowerLevel] = [:]
      for (key, level) in byTask {
        if let taskId = Int(key) {
          inner[taskId] = level
        }
      }
      if !inner.isEmpty { result[listId] = inner }
    }
    return result
  }

  private func writeAll(_ all: [String: [Int: EisenhowerLevel]]) {
    var encoded: [String: [String: EisenhowerLevel]] = [:]
    for (listId, byTask) in all {
      var inner: [String: EisenhowerLevel] = [:]
      for (taskId, level) in byTask {
        inner[String(taskId)] = level
      }
      encoded[listId] = inner
    }
    if let data = try? JSONEncoder().encode(encoded) {
      defaults.set(data, forKey: defaultsKey)
    }
  }
}
