import Foundation
import TaktWorkspace

@MainActor
extension WorkspaceModel {
  /// Opens the task's list in the outline with completed tasks showing and
  /// its branch unfolded, and selects it: Review's "Reveal in list" and the
  /// task menu's "Go to the task's list", as `go` is on the Mac.
  func revealInList(_ task: WorkspaceTask, isPad: Bool) {
    let scope = ListScope.list(task.listId)
    UserDefaults.standard.set(false, forKey: "outlineHidesCompleted")
    let foldKey = "outlineFolds.\(scope.storageKey)"
    var folds = Set(UserDefaults.standard.stringArray(forKey: foldKey) ?? [])
    var ancestors: Set<String> = []
    var parent = task.parentTaskId
    while let id = parent, let ancestor = self.task(id) {
      ancestors.insert(id)
      parent = ancestor.parentTaskId
    }
    folds.subtract(ancestors)
    UserDefaults.standard.set(Array(folds).sorted(), forKey: foldKey)
    navigation.viewMode = .outline
    navigation.open(scope, isPad: isPad)
    navigation.selectedTaskID = task.id
    // A new outline reads the defaults above; one already open hears this.
    navigation.revealRequest = RevealRequest(
      taskID: task.id, scope: scope, ancestorIDs: ancestors, serial: (navigation.revealRequest?.serial ?? 0) + 1)
  }
}
