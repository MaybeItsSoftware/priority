import Foundation

/// Single fan-out point for "something a visible-task cache depends on just changed."
/// Producers (TaskRepository, NavigationState, the per-feature managers) call
/// `invalidate()` from their property `didSet`s; the lone subscriber today
/// (`AppCoordinator`) routes that into `TaskListViewModel.invalidateCaches()`.
///
/// Replaces the old per-manager `onCacheRelevantChange` callback chain so that
/// adding a new cache-relevant property is a one-line `bus.invalidate()` rather
/// than threading another closure through `setupChildCallbacks()`.
@MainActor
final class CacheInvalidationBus {
  private var handlers: [() -> Void] = []

  /// Nonisolated so callers can write `CacheInvalidationBus()` as a default
  /// argument from synchronous, non-MainActor contexts (e.g. nonisolated
  /// `init` parameter defaults on `@MainActor` types).
  nonisolated init() {}

  func invalidate() {
    for handler in handlers { handler() }
  }

  /// Subscribers are retained for the lifetime of the bus. The bus itself is
  /// owned by `AppCoordinator`, which outlives every manager that talks to it,
  /// so an unsubscribe API would only carry weight in tests — and tests build a
  /// fresh bus per case.
  func subscribe(_ handler: @escaping () -> Void) {
    handlers.append(handler)
  }
}
