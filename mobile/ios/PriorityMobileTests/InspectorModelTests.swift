import PriorityCore
import PriorityWorkspace
import XCTest
@testable import Priority

@MainActor
final class InspectorModelTests: XCTestCase {
  private var model: WorkspaceModel!
  private var draftsURL: URL!
  private var task: WorkspaceTask!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    draftsURL = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString).json")
    let inbox = try XCTUnwrap(model.inbox)
    task = try XCTUnwrap(model.createTask("Write report", listID: inbox.id))
  }

  private func makeInspector() -> InspectorModel {
    let inspector = InspectorModel(taskID: task.id, draftsURL: draftsURL)
    inspector.load(model)
    return inspector
  }

  func testSavingWritesEveryEditedFieldInOneUndoStep() throws {
    let inspector = makeInspector()
    inspector.edit(model) {
      $0.title = "Write the report"
      $0.notes = "Section two first"
      $0.estimateMinutes = "45"
      $0.priority = 2
      $0.tags = "work, writing"
    }
    XCTAssertTrue(inspector.isDirty)
    XCTAssertTrue(inspector.save(model))
    XCTAssertFalse(inspector.isDirty)

    let saved = try model.store.taskEditorSnapshot(for: task.id)
    XCTAssertEqual(saved.title, "Write the report")
    XCTAssertEqual(saved.notes, "Section two first")
    XCTAssertEqual(saved.estimateSeconds, 2_700)
    XCTAssertEqual(saved.metadata.priority, 2)
    XCTAssertEqual(saved.metadata.tags, ["work", "writing"])
    XCTAssertEqual(model.undoLabel, "Edit Task")

    model.undo()
    XCTAssertEqual(try model.store.task(id: task.id)?.title, "Write report")
  }

  func testAnUnsavedDraftSurvivesTheInspectorClosing() {
    let first = makeInspector()
    first.edit(model) { $0.notes = "Half-typed" }
    // Closed without saving, as when the app is killed mid-edit.
    let second = makeInspector()
    XCTAssertEqual(second.values?.notes, "Half-typed")
    XCTAssertTrue(second.isDirty)
  }

  func testAnUntouchedFieldFollowsAChangeMadeElsewhere() throws {
    let inspector = makeInspector()
    inspector.edit(model) { $0.notes = "Mine" }
    model.rename(task.id, to: "Renamed on the Mac")
    inspector.refresh(model)
    XCTAssertEqual(inspector.values?.title, "Renamed on the Mac")
    XCTAssertEqual(inspector.values?.notes, "Mine")
    XCTAssertTrue(inspector.conflicts.isEmpty)
  }

  func testAFieldChangedOnBothSidesIsAConflictToResolve() throws {
    let inspector = makeInspector()
    inspector.edit(model) { $0.title = "My title" }
    model.rename(task.id, to: "Their title")
    inspector.refresh(model)
    XCTAssertEqual(inspector.conflicts, [.title])
    XCTAssertFalse(inspector.save(model), "A conflicted draft must not save")

    inspector.resolve(.title, useSaved: false, model: model)
    XCTAssertTrue(inspector.conflicts.isEmpty)
    XCTAssertTrue(inspector.save(model))
    XCTAssertEqual(try model.store.task(id: task.id)?.title, "My title")
  }

  func testDueMovesBetweenDayAndExactTime() throws {
    let inspector = makeInspector()
    inspector.setDueKind(.day, model: model)
    XCTAssertEqual(inspector.dueKind, .day)
    XCTAssertEqual(inspector.values?.dueDate, TaskCalendarDate.string(.now))
    inspector.setDueKind(.time, model: model)
    XCTAssertEqual(inspector.dueKind, .time)
    XCTAssertNil(inspector.values?.dueDate)
    XCTAssertTrue(inspector.save(model))
    XCTAssertNotNil(try model.store.task(id: task.id)?.dueAt)
    inspector.setDueKind(.none, model: model)
    XCTAssertTrue(inspector.save(model))
    XCTAssertNil(try model.store.task(id: task.id)?.dueAt)
  }

  func testConditionsGroupAndUngroup() throws {
    let conditions = try model.store.conditions(in: model.workspace.id)
    guard conditions.count >= 2 else { throw XCTSkip("Workspace seeded without conditions") }
    let inspector = makeInspector()
    inspector.addRequirement(conditions[0].id, model: model)
    inspector.addRequirement(conditions[1].id, toGroup: 0, model: model)
    XCTAssertEqual(inspector.values?.requirementGroups, [[conditions[0].id, conditions[1].id]])
    inspector.removeRequirement(conditions[0].id, fromGroup: 0, model: model)
    inspector.removeRequirement(conditions[1].id, fromGroup: 0, model: model)
    XCTAssertNil(inspector.values?.requirementGroups)
  }

  func testPlacementIsWrittenStraightAway() throws {
    let inspector = makeInspector()
    inspector.setPlanned(true, model: model)
    XCTAssertTrue(inspector.isPlanned)
    inspector.setColumn("waiting-on", model: model)
    XCTAssertEqual(try model.store.kanbanColumn(for: task.id), "waiting-on")
    XCTAssertFalse(inspector.isPlanned)
    inspector.setQuadrant(.schedule, model: model)
    XCTAssertEqual(inspector.quadrant, .schedule)
    inspector.setQuadrant(nil, model: model)
    XCTAssertNil(inspector.quadrant)
  }

  func testDailyProgressAttachesADaily() throws {
    let inspector = makeInspector()
    inspector.edit(model, immediate: true) { $0.dailyProgress = true }
    XCTAssertTrue(inspector.save(model))
    XCTAssertTrue(model.isDaily(task.id))
  }
}

@MainActor
final class QuickAddModelTests: XCTestCase {
  private var model: WorkspaceModel!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
  }

  func testChipsShowWhatTheTrailingWordsSet() {
    let quickAdd = QuickAddModel()
    quickAdd.text = "Write the release notes 45m #work !1"
    XCTAssertEqual(quickAdd.capture().title, "Write the release notes")
    XCTAssertEqual(quickAdd.chips(), ["45m", "#work", "!1"])
    quickAdd.text = "Read 30 pages"
    XCTAssertEqual(quickAdd.chips(), [])
  }

  func testAddFilesIntoTheInboxByDefaultWithTokensReadOff() throws {
    let quickAdd = QuickAddModel()
    quickAdd.prepare(model)
    quickAdd.text = "Call the dentist 15m"
    let task = try XCTUnwrap(quickAdd.add(model))
    XCTAssertEqual(task.title, "Call the dentist")
    XCTAssertEqual(task.estimateSeconds, 900)
    XCTAssertEqual(task.listId, model.inbox?.id)
    XCTAssertEqual(quickAdd.text, "", "The field clears for the next task")
    XCTAssertEqual(quickAdd.added, ["Call the dentist"])
  }

  func testAddCanPlanForTodayInTheSameUndoStep() throws {
    let quickAdd = QuickAddModel()
    quickAdd.prepare(model)
    quickAdd.plansToday = true
    quickAdd.text = "Groceries"
    let task = try XCTUnwrap(quickAdd.add(model))
    XCTAssertTrue(model.isPlannedToday(task.id))
    model.undo()
    XCTAssertNil(try model.store.task(id: task.id))
  }

  func testDestinationsIncludeNestedListsAndOpeningFromAListChoosesIt() throws {
    let work = try XCTUnwrap(model.createList(named: "Work"))
    let nested = try XCTUnwrap(model.createNestedList(named: "Planning", inList: work.id, parentTaskID: nil))
    model.reloadStructureNow()
    let destinations = QuickAddModel.destinations(in: model.structure)
    let entry = try XCTUnwrap(destinations.first { $0.id == nested.id })
    XCTAssertEqual(entry.path, "Work › Planning")
    XCTAssertEqual(entry.parentTaskID, nested.id)

    model.navigation.quickAddListID = work.id
    let quickAdd = QuickAddModel()
    quickAdd.prepare(model)
    XCTAssertEqual(quickAdd.destinationID, work.id)

    quickAdd.destinationID = nested.id
    quickAdd.text = "Draft goals"
    let task = try XCTUnwrap(quickAdd.add(model))
    XCTAssertEqual(task.parentTaskId, nested.id)
  }

  func testOpeningForASubtaskFilesUnderThatTask() throws {
    let inbox = try XCTUnwrap(model.inbox)
    let parent = try XCTUnwrap(model.createTask("Parent", listID: inbox.id))
    model.navigation.quickAddParentTaskID = parent.id
    let quickAdd = QuickAddModel()
    quickAdd.prepare(model)
    quickAdd.text = "Child"
    let child = try XCTUnwrap(quickAdd.add(model))
    XCTAssertEqual(child.parentTaskId, parent.id)
  }
}
