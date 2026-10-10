import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

@MainActor
final class ConditionsTests: XCTestCase {
  func testRenamingAndArchivingKeepTheRequirementsThatNameTheCondition() throws {
    let model = try WorkspaceModel.temporary()
    let condition = try XCTUnwrap(model.createCondition(named: "Lab", isLocation: false))
    let task = try XCTUnwrap(model.createTask("Run the assay", listID: try XCTUnwrap(model.inbox).id))
    let inspector = InspectorModel(taskID: task.id, draftsURL: FileManager.default.temporaryDirectory
      .appending(path: "drafts-\(UUID().uuidString).json"))
    inspector.load(model)
    inspector.addRequirement(condition.id, model: model)
    XCTAssertTrue(inspector.save(model))

    var catalogue = try ConditionsCatalogue.load(store: model.store, workspaceID: model.workspace.id)
    XCTAssertEqual(catalogue.usage[condition.id], 1)

    model.saveCondition(condition, name: "Wet lab", isLocation: true)
    catalogue = try ConditionsCatalogue.load(store: model.store, workspaceID: model.workspace.id)
    let renamed = try XCTUnwrap(catalogue.conditions.first { $0.id == condition.id })
    XCTAssertEqual(renamed.name, "Wet lab")
    XCTAssertTrue(renamed.isLocation)

    model.saveCondition(renamed, isArchived: true)
    catalogue = try ConditionsCatalogue.load(store: model.store, workspaceID: model.workspace.id)
    XCTAssertTrue(catalogue.archived.contains { $0.id == condition.id })
    XCTAssertFalse(catalogue.active.contains { $0.id == condition.id })
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: task.id).values.requirementGroups, [[condition.id]])

    model.undo()
    catalogue = try ConditionsCatalogue.load(store: model.store, workspaceID: model.workspace.id)
    XCTAssertTrue(catalogue.active.contains { $0.id == condition.id }, "archiving is one undo step")
  }
}

@MainActor
final class ParityTests: XCTestCase {
  func testProgressCountsTheWholeBranchAndTheTimeLogged() throws {
    let model = try WorkspaceModel.temporary()
    let inbox = try XCTUnwrap(model.inbox)
    let parent = try XCTUnwrap(model.createTask("Parent", listID: inbox.id))
    let child = try model.store.createTask(listId: inbox.id, title: "Child", parentTaskId: parent.id)
    _ = try model.store.createTask(listId: inbox.id, title: "Grandchild", parentTaskId: child.id)
    // Closing a task closes its open subtasks with it, so both are done.
    try model.store.setStatus(.completed, for: child.id)
    let progress = try TaskProgress.load(store: model.store, taskID: parent.id)
    XCTAssertEqual(progress.subtasks, 2)
    XCTAssertEqual(progress.subtasksDone, 2)
    XCTAssertEqual(progress.summary, "2 of 2 subtasks done")
  }

  func testRestoringTheLastArchivedListAndFoldingEveryFolder() throws {
    let model = try WorkspaceModel.temporary()
    let first = try XCTUnwrap(model.performReturning { try $0.createList(workspaceId: model.workspace.id, name: "First") })
    let second = try XCTUnwrap(model.performReturning { try $0.createList(workspaceId: model.workspace.id, name: "Second") })
    model.setArchived(true, list: first.id)
    model.setArchived(true, list: second.id)
    model.reloadStructureNow()
    model.restoreLastArchivedList()
    model.reloadStructureNow()
    XCTAssertEqual(model.structure.archivedLists.map(\.id), [first.id])

    let folder = try XCTUnwrap(model.performReturning { try $0.createFolder(workspaceId: model.workspace.id, name: "F") })
    model.reloadStructureNow()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ParityTests-\(UUID().uuidString)"))
    model.setAllFoldersExpanded(false, defaults: defaults)
    XCTAssertEqual(defaults.object(forKey: WorkspaceModel.folderExpandedKey(folder.id)) as? Bool, false)
    model.setAllFoldersExpanded(true, defaults: defaults)
    XCTAssertEqual(defaults.object(forKey: WorkspaceModel.folderExpandedKey(folder.id)) as? Bool, true)
  }
}
