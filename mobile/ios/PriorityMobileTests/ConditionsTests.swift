import PriorityCore
import PriorityWorkspace
import XCTest
@testable import Priority

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
