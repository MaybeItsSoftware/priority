import Foundation
import Observation
import PriorityWorkspace

/// One read a screen keeps current.
///
/// This is the app's observation of the store. A screen keys a query on the
/// model's `revision` and on its own scope with `.task(id:)`; when either
/// moves, the read runs again on a background executor and the result lands on
/// the main actor only if it differs and nothing newer was asked for in the
/// meantime. A screen that is not on screen has no running `.task`, so it
/// reads nothing: only the visible scope is observed.
///
/// (The store keeps its GRDB pool internal, so `ValueObservation` cannot be
/// attached from outside the package. Every write the app makes goes through
/// `WorkspaceModel.perform`, which moves `revision`, and other processes'
/// writes move it through `PRAGMA data_version` — the same two signals a
/// `ValueObservation` would turn into a re-fetch.)
@MainActor
@Observable
final class StoreQuery<Value: Sendable & Equatable> {
  private(set) var value: Value
  private(set) var isLoaded = false
  @ObservationIgnored private var generation = 0

  init(_ initial: Value) {
    value = initial
  }

  /// Reads `fetch` off the main actor and lands it.
  func load(_ store: WorkspaceStore, _ fetch: @escaping @Sendable (WorkspaceStore) throws -> Value) async {
    generation &+= 1
    let mine = generation
    let result = await Task.detached(priority: .userInitiated) {
      Result { try fetch(store) }
    }.value
    guard mine == generation, !Task.isCancelled else { return }
    switch result {
    case .success(let fresh):
      if !isLoaded || fresh != value { value = fresh }
    case .failure:
      break
    }
    if !isLoaded { isLoaded = true }
  }

  /// Replaces the value straight away — for an optimistic change the next
  /// read will confirm.
  func set(_ value: Value) {
    self.value = value
  }
}

/// What a query's `.task(id:)` is keyed on: the workspace's revision and
/// whatever else the read depends on.
struct QueryKey<Scope: Hashable>: Hashable {
  let revision: Int
  let scope: Scope
}
