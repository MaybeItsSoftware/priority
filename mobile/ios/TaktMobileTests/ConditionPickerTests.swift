import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

/// The conditions picker's shaping, held to the same cases as Android's
/// `ConditionPickerTest`.
@MainActor
final class ConditionPickerTests: XCTestCase {
  private var model: WorkspaceModel!
  private var home: TaskCondition!
  private var campus: TaskCondition!
  private var laptop: TaskCondition!
  private var mat: TaskCondition!
  private var lab: TaskCondition!

  override func setUpWithError() throws {
    model = try WorkspaceModel.temporary()
    home = try XCTUnwrap(model.createCondition(named: "Home", category: "Location"))
    campus = try XCTUnwrap(model.createCondition(named: "Campus", category: "Location"))
    laptop = try XCTUnwrap(model.createCondition(named: "Laptop", category: "Equipment"))
    mat = try XCTUnwrap(model.createCondition(named: "Floor space", category: nil))
    let made = try XCTUnwrap(model.createCondition(named: "Lab", category: nil))
    model.saveCondition(made, isArchived: true)
    lab = try XCTUnwrap(try model.store.conditions(in: model.workspace.id).first { $0.id == made.id })
  }

  private var all: [TaskCondition] { [home, campus, laptop, mat, lab] }
  private var live: [TaskCondition] { all.filter { !$0.isArchived } }

  func testWithNothingTypedTheRowsSitUnderTheCoresHeadings() {
    let list = ConditionPicker.list(
      offered: TaskConditionSection.sections(live), searchable: live, all: all, query: "",
      isOn: { $0 == self.home.id }, exclusiveRadio: true)
    XCTAssertFalse(list.isSearching)
    XCTAssertNil(list.newName)
    XCTAssertEqual(list.sections.map(\.title), ["Location", "Equipment", "Other"])
    let location = list.sections[0].rows
    XCTAssertEqual(location.map(\.condition.name), ["Home", "Campus"])
    XCTAssertTrue(location.allSatisfy(\.isExclusive))
    XCTAssertTrue(location[0].isOn)
    XCTAssertFalse(list.sections[1].rows[0].isExclusive)
    XCTAssertNil(location[0].category)
  }

  func testPlacesAreRadiosOnlyWhenSayingWhereYouAre() {
    let list = ConditionPicker.list(
      offered: TaskConditionSection.sections(live), searchable: live, all: all, query: "",
      isOn: { _ in false }, exclusiveRadio: false)
    XCTAssertFalse(list.sections.flatMap(\.rows).contains(where: \.isExclusive))
  }

  func testTypingRanksOneFlatListAndNamesEachRowsCategory() throws {
    let list = ConditionPicker.list(
      offered: TaskConditionSection.sections(live), searchable: live, all: all, query: "lap",
      isOn: { _ in false }, exclusiveRadio: true)
    XCTAssertTrue(list.isSearching)
    let section = try XCTUnwrap(list.sections.first)
    XCTAssertEqual(list.sections.count, 1)
    XCTAssertNil(section.title)
    XCTAssertEqual(section.rows.first?.condition.name, "Laptop")
    XCTAssertEqual(section.rows.first?.category, "Equipment")
    XCTAssertEqual(list.newName, "lap")
  }

  func testANameAlreadyTakenIsNotOfferedAgainArchivedOrNot() {
    XCTAssertNil(ConditionPicker.list(
      offered: [], searchable: live, all: all, query: " laptop ", isOn: { _ in false }, exclusiveRadio: false).newName)
    let archived = ConditionPicker.list(
      offered: [], searchable: live, all: all, query: "LAB", isOn: { _ in false }, exclusiveRadio: false)
    XCTAssertNil(archived.newName)
    XCTAssertTrue(archived.isEmpty)
    XCTAssertEqual(ConditionPicker.list(
      offered: [], searchable: live, all: all, query: "Desk", isOn: { _ in false }, exclusiveRadio: false).newName,
      "Desk")
  }

  func testSummariesReadInWords() {
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
    let name: (String) -> String = { byID[$0] ?? "?" }
    XCTAssertEqual(ConditionPicker.requirementSummary(nil, name: name), "Anytime")
    XCTAssertEqual(
      ConditionPicker.requirementSummary([[home.id, campus.id], [laptop.id]], name: name), "Home or Campus + Laptop")
    XCTAssertEqual(ConditionPicker.alternatives(to: home.id, in: [[home.id, campus.id]], name: name), "Campus")
    XCTAssertNil(ConditionPicker.alternatives(to: laptop.id, in: [[laptop.id]], name: name))
    XCTAssertEqual(
      ConditionPicker.requirementSummary([["!" + home.id], [campus.id, "!" + laptop.id]], name: name),
      "not Home + Campus or not Laptop")
    XCTAssertEqual(ConditionPicker.alternatives(to: campus.id, in: [[campus.id, "!" + laptop.id]], name: name), "not Laptop")
    XCTAssertEqual(ConditionPicker.nowSummary(all, selected: [laptop.id, home.id]), "Home · Laptop")
    XCTAssertNil(ConditionPicker.nowSummary(all, selected: []))
  }

  func testTickingFromTheSheetJoinsASecondPlaceToTheFirst() throws {
    let task = try XCTUnwrap(model.createTask("Write up", listID: try XCTUnwrap(model.inbox).id))
    let inspector = InspectorModel(taskID: task.id, draftsURL: FileManager.default.temporaryDirectory
      .appending(path: "drafts-\(UUID().uuidString).json"))
    inspector.load(model)
    let places: Set<String> = [home.id, campus.id]
    inspector.toggleRequirement(laptop.id, places: places, model: model)
    inspector.toggleRequirement(home.id, places: places, model: model)
    inspector.toggleRequirement(campus.id, places: places, model: model)
    XCTAssertEqual(inspector.values?.requirementGroups, [[laptop.id], [home.id, campus.id]])
    inspector.toggleRequirement(laptop.id, places: places, model: model)
    XCTAssertEqual(inspector.values?.requirementGroups, [[home.id, campus.id]])
    XCTAssertTrue(inspector.save(model))
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: task.id).values.requirementGroups, [[home.id, campus.id]])
  }

  func testNotTicksAConditionAsNotHoldingAndTicksItOff() throws {
    let task = try XCTUnwrap(model.createTask("Shop", listID: try XCTUnwrap(model.inbox).id))
    let inspector = InspectorModel(taskID: task.id, draftsURL: FileManager.default.temporaryDirectory
      .appending(path: "drafts-\(UUID().uuidString).json"))
    inspector.load(model)
    inspector.negateRequirement(home.id, model: model)
    XCTAssertEqual(inspector.values?.requirementGroups, [["!" + home.id]])
    XCTAssertEqual(inspector.requirementLabel("!" + home.id), "not Home")
    inspector.negateRequirement(home.id, model: model)
    XCTAssertNil(inspector.values?.requirementGroups)
  }

  func testTheSheetsTogglePutsOnePlaceAtATimeAmongTheConditionsItWasGiven() {
    let focus = FocusModel(model: model)
    focus.toggleCondition(home, among: all)
    focus.toggleCondition(laptop, among: all)
    focus.toggleCondition(campus, among: all)
    XCTAssertEqual(focus.conditionIDs, [campus.id, laptop.id])
  }
}
