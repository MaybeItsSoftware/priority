import Foundation

/// Which per-task state survives a reconcile against the open task list.
///
/// Both stores that hang off a task id — its matrix coordinate and its slot in
/// the priority queue — used to keep only what was still in the open list,
/// which quietly made *completing a task* a destructive edit to both: tick
/// something and its placement and its rank were deleted, so reopening it — by
/// undo or by hand — brought the task back stripped of both. Undo covers task
/// mutations, not the judgements the mutation destroyed on the way past, so
/// there was nothing to press.
///
/// Absence from the open list is simply not evidence that a task is gone. It
/// also means completed, filtered, or not fetched yet.
public enum CompletionRetention {

  /// A real Checkvist id keeps its state whatever the open list currently
  /// says. Only a negative id — the optimistic temp id an offline create holds
  /// until the server answers with a real one — is pruned once it is no longer
  /// in the list, because that id will never refer to anything again.
  ///
  /// The cost of keeping the rest is an entry per task ever placed or ranked,
  /// around forty bytes, which shows nothing: both readers iterate tasks and
  /// look the state up, never the other way round.
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
