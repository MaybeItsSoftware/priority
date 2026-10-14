import Foundation
import TaktCore
import TaktWorkspace

/// Organising the Conditions tab: moving conditions and categories, renaming
/// a category, merging two conditions, folding, and showing what a condition
/// holds back. Every write is the Rust core's (`core/src/conditions/organise.rs`),
/// one undo step each, so the order and the merges reach the phones too.
@MainActor
extension WorkspaceViewModel {
  private var foldedConditionsKey: String? { workspace.map { "conditions-folded-\($0.id)" } }

  /// The headings folded in the Conditions half, by section id, as they were
  /// left in this workspace.
  func restoreFoldedConditionSections() {
    guard let key = foldedConditionsKey else { return }
    foldedConditionSections = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  private func saveFoldedConditionSections() {
    guard let key = foldedConditionsKey else { return }
    UserDefaults.standard.set(foldedConditionSections.sorted(), forKey: key)
  }

  /// The heading the cursor is under in the Conditions half.
  private var sectionUnderCursor: TaskConditionSection? {
    let stop = conditionsCursorStop
    let sections = liveConditionSections
    switch stop {
    case .folded(let id): return sections.first { $0.id == id }
    case .condition(let id), .available(let id): return sections.first { $0.conditions.contains { $0.id == id } }
    case .add, .archived: return nil
    }
  }

  func runConditionsOrganiseCommand(_ id: WorkspaceCommandID) {
    switch id {
    case .conditionsMoveUp: moveConditionUnderCursor(by: -1)
    case .conditionsMoveDown: moveConditionUnderCursor(by: 1)
    case .conditionsMoveCategoryUp: moveCategoryUnderCursor(by: -1)
    case .conditionsMoveCategoryDown: moveCategoryUnderCursor(by: 1)
    case .conditionsRenameCategory:
      if let section = sectionUnderCursor {
        presentOverlay(.renameConditionCategory(WorkspaceConditionCategoryRenameRequest(
          category: section.category, title: section.title)))
      }
    case .conditionsMerge:
      if let condition = conditionUnderCursor {
        presentOverlay(.conditionFinder(WorkspaceConditionFinderRequest(purpose: .merge(from: condition.id))))
      }
    case .conditionsShowTasks:
      if let condition = conditionUnderCursor { toggleTasksRequiring(condition) }
    case .conditionsFold: foldUnderCursor()
    case .conditionsFoldAll: foldAllConditionSections()
    default: break
    }
  }

  // MARK: Order

  /// `⌥↑`/`⌥↓`: within its heading. From "Available now" the cursor follows
  /// it into the lower half, where the order is drawn.
  private func moveConditionUnderCursor(by offset: Int) {
    guard let store, let condition = conditionUnderCursor else { return }
    conditionsCursor = .condition(condition.id)
    perform {
      if try store.moveCondition(id: condition.id, by: offset) { reloadNextUpNow() }
    }
  }

  /// `⌥⇧↑`/`⌥⇧↓`: the whole heading the cursor is under.
  private func moveCategoryUnderCursor(by offset: Int) {
    guard let store, let workspace, let section = sectionUnderCursor else { return }
    perform {
      if try store.moveConditionCategory(section.category, in: workspace.id, by: offset) { reloadNextUpNow() }
    }
  }

  // MARK: Renaming and merging

  /// Every condition under a heading filed under `name`, in one undo step.
  /// Location keeps its name: being filed there is what makes a place.
  func renameConditionCategory(_ category: String?, to name: String) {
    guard let store, let workspace else { return }
    guard category != TaskConditionSection.locationCategory else {
      errorMessage = "Location keeps its name: it is what makes a condition a place."
      return
    }
    let wasFolded = liveConditionSections.first { $0.category == category }.map { foldedConditionSections.contains($0.id) }
    perform {
      try store.renameConditionCategory(category, to: name, in: workspace.id)
      reloadNextUpNow(); taskEditor.refresh(store: store)
    }
    // The fold goes with the heading.
    if wasFolded == true, let renamed = liveConditionSections.first(where: {
      $0.category?.caseInsensitiveCompare(name) == .orderedSame
    }) {
      foldedConditionSections.insert(renamed.id)
      saveFoldedConditionSections()
    }
  }

  /// `from` into `into`: its tasks need `into` instead, and it is archived.
  func mergeCondition(_ from: TaskCondition, into: TaskCondition) {
    guard let store, from.id != into.id else { return }
    perform {
      try store.mergeConditions(from.id, into: into.id)
      reloadNextUpNow(); taskEditor.refresh(store: store)
    }
    // What holds now followed it into the workspace; read it back.
    restoreFocusContext()
    conditionsCursor = .condition(into.id)
    if conditionTasksShownFor == from.id { conditionTasksShownFor = nil }
  }

  // MARK: What a condition holds back

  /// `o`: the open tasks that need the condition, under its row; again hides
  /// them.
  func toggleTasksRequiring(_ condition: TaskCondition) {
    guard conditionTasksShownFor != condition.id else {
      conditionTasksShownFor = nil
      return
    }
    guard let store, let workspace else { return }
    conditionTasks = (try? store.tasksRequiring(condition: condition.id, in: workspace.id)) ?? []
    conditionTasksShownFor = condition.id
    conditionsCursor = .condition(condition.id)
  }

  /// Selects one of those tasks where it lives.
  func revealRequiringTask(_ id: String) {
    guard let task = try? store?.task(id: id) else { return }
    revealTask(task)
  }

  // MARK: Folding

  private func foldUnderCursor() {
    if conditionsCursorStop == .archived {
      showsArchivedConditions.toggle()
      return
    }
    guard let section = sectionUnderCursor else { return }
    if foldedConditionSections.remove(section.id) == nil {
      foldedConditionSections.insert(section.id)
      conditionsCursor = .folded(section.id)
    } else {
      conditionsCursor = section.conditions.first.map { .condition($0.id) }
    }
    saveFoldedConditionSections()
  }

  /// `⇧Z`: every heading folded, or — when they all are — every one open.
  func foldAllConditionSections() {
    let ids = Set(liveConditionSections.map(\.id))
    foldedConditionSections = ids.isSubset(of: foldedConditionSections) ? [] : ids
    saveFoldedConditionSections()
  }

  func toggleConditionSectionFold(_ section: TaskConditionSection) {
    if foldedConditionSections.remove(section.id) == nil { foldedConditionSections.insert(section.id) }
    saveFoldedConditionSections()
  }

  // MARK: Saying where you are

  /// `gw`: the places, and Anywhere, in a finder, without leaving the work.
  func presentPlaceFinder() {
    presentOverlay(.conditionFinder(WorkspaceConditionFinderRequest(purpose: .place)))
  }
}
