import Foundation

/// Which stored matrix coordinates survive a reconcile against the open tasks.
///
/// The store used to keep only coordinates whose task was still in the open
/// list, which quietly made *completing a task* a destructive edit to the
/// matrix: tick something and its placement was deleted, so reopening it — by
/// undo or by hand — brought the task back and left it unplaced. Undo covers
/// task mutations, not the placement it took with it, so there was nothing to
/// press. The coordinate is the one thing on the plot the user actually
/// decided, and it was the cheapest thing in the app to throw away.
///
/// Absence from the open list is simply not evidence that a task is gone. It
/// also means completed, filtered, or not fetched yet.
public enum MatrixLevelRetention {

  /// A real Checkvist id keeps its coordinate whatever the open list currently
  /// says. Only a negative id — the optimistic temp id an offline create holds
  /// until the server answers with a real one — is pruned once it is no longer
  /// in the list, because that id will never refer to anything again.
  ///
  /// The cost of keeping the rest is a dictionary entry per task ever placed,
  /// around forty bytes, which draws nothing: the plot iterates tasks and looks
  /// coordinates up, never the other way round.
  public static func retained(
    storedIds: some Sequence<Int>,
    openTaskIds: Set<Int>
  ) -> Set<Int> {
    // No tasks at all is the pre-fetch state rather than an empty list, and
    // pruning against it would drop every pending offline placement on launch.
    guard !openTaskIds.isEmpty else { return Set(storedIds) }
    return Set(storedIds.filter { $0 > 0 || openTaskIds.contains($0) })
  }
}
