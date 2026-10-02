import Foundation
import Observation
import PriorityCore
import PriorityWorkspace

/// One task's editor: the desktop's `WorkspaceTaskEditor`, for a single task.
///
/// Edits go into a `TaskEditorDraft` — never straight into the store — and
/// are saved through `WorkspaceStore.saveTaskEditor`, the call the Mac's Save
/// button makes, so a field edited here and on the Mac is the same write and
/// the same undo step. Saving is automatic: a little after the last change,
/// and at once when the inspector goes away.
///
/// The draft outlives the screen. An unsaved draft is written to
/// `TaskEditorDraftStore` in the app group, so an edit interrupted by the
/// app being killed is still there when the task is opened again. When the
/// task changes underneath it (a sync, a swipe in the outline, the widget),
/// `refresh` reconciles: untouched fields follow the store, and a field
/// changed on both sides becomes a conflict to resolve by hand.
@MainActor
@Observable
final class InspectorModel {
  let taskID: String
  private(set) var draft: TaskEditorDraft?
  private(set) var task: WorkspaceTask?
  /// Why the last save or read failed, shown in the inspector rather than as
  /// an alert over everything.
  private(set) var error: String?
  private(set) var conditions: [TaskCondition] = []
  private(set) var kanbanColumn: String?
  private(set) var boardColumns: [WorkspaceKanbanColumn] = WorkspaceKanbanColumn.blitzitDefaults
  private(set) var matrix = TaskMatrixPosition(urgency: nil, importance: nil)
  private(set) var isPlanned = false
  private(set) var loggedSeconds = 0
  private(set) var listName = ""

  /// How long after the last keystroke a text field saves.
  var textSaveDelay: Duration = .milliseconds(1_200)
  /// How long after a toggle or picker change the edit saves.
  var controlSaveDelay: Duration = .milliseconds(250)

  @ObservationIgnored private let draftStore: TaskEditorDraftStore
  @ObservationIgnored private var pendingSave: Task<Void, Never>?

  init(taskID: String, draftsURL: URL = AppGroup.draftsURL) {
    self.taskID = taskID
    self.draftStore = TaskEditorDraftStore(fileURL: draftsURL)
  }

  var values: TaskEditorValues? { draft?.values }
  var isDirty: Bool { draft?.isDirty ?? false }
  var conflicts: [TaskEditorField] {
    TaskEditorField.allCases.filter { draft?.conflicts.contains($0) == true }
  }
  var isUnavailable: Bool { draft?.isUnavailable ?? false }

  // MARK: - Loading

  /// Opens the task: restores a draft left from last time, or starts one from
  /// the saved values, then reconciles it with what is saved now.
  func load(_ model: WorkspaceModel) {
    let store = model.store
    do {
      let saved = try store.taskEditorSnapshot(for: taskID)
      var draft = (try? draftStore.load())?.first { $0.baseline.taskId == taskID } ?? TaskEditorDraft(snapshot: saved)
      draft.reconcile(with: saved)
      self.draft = draft
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    loadSurroundings(model)
  }

  /// The store changed: follow it where the draft has not been touched.
  func refresh(_ model: WorkspaceModel) {
    guard var draft else { return load(model) }
    do {
      draft.reconcile(with: try model.store.taskEditorSnapshot(for: taskID))
    } catch WorkspaceStoreError.missingTask {
      draft.isUnavailable = true
    } catch {
      self.error = error.localizedDescription
    }
    if draft != self.draft { self.draft = draft }
    loadSurroundings(model)
  }

  /// What sits around the draft: the task itself, its board and matrix
  /// placement, the condition catalogue and the time logged against it.
  private func loadSurroundings(_ model: WorkspaceModel) {
    let store = model.store
    task = try? store.task(id: taskID)
    guard let task else { return }
    listName = model.listName(for: task.listId)
    conditions = (try? store.conditions(in: model.workspace.id)) ?? []
    let metadata = try? store.boardMetadata(for: [taskID])
    kanbanColumn = metadata?.columns[taskID]
    matrix = metadata?.positions[taskID] ?? TaskMatrixPosition(urgency: nil, importance: nil)
    isPlanned = kanbanColumn == NextUpSelector.todayColumnID
    loggedSeconds = ((try? store.workBlocks(for: taskID)) ?? []).reduce(0) { $0 + $1.seconds }
    let key = "\(task.listId)/\(task.parentTaskId ?? "root")"
    if let configurations = try? store.kanbanBoardConfigurations(legacy: [:], currentKey: key) {
      let scoped = configurations[key] ?? configurations["\(task.listId)/root"]
      if let data = scoped, let columns = try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: data),
        !columns.isEmpty {
        boardColumns = columns
      }
    }
  }

  // MARK: - Editing

  /// Changes the draft and schedules the save. `immediate` is for controls —
  /// a toggle has nothing more coming — rather than typing.
  func edit(_ model: WorkspaceModel, immediate: Bool = false, _ change: (inout TaskEditorValues) -> Void) {
    guard var draft else { return }
    let wasUnavailable = draft.isUnavailable
    change(&draft.values)
    draft.reconcile(with: draft.baseline)
    draft.isUnavailable = wasUnavailable
    guard draft != self.draft else { return }
    self.draft = draft
    error = nil
    persistDraft()
    scheduleSave(model, after: immediate ? controlSaveDelay : textSaveDelay)
  }

  func resolve(_ field: TaskEditorField, useSaved: Bool, model: WorkspaceModel) {
    guard var draft else { return }
    draft.resolve(field, useSaved: useSaved)
    self.draft = draft
    persistDraft()
    scheduleSave(model, after: controlSaveDelay)
  }

  private func scheduleSave(_ model: WorkspaceModel, after delay: Duration) {
    pendingSave?.cancel()
    pendingSave = Task { @MainActor [weak self, weak model] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, let model else { return }
      self.save(model)
    }
  }

  /// Saves now if there is anything to save. Returns whether the draft is
  /// clean afterwards.
  @discardableResult
  func save(_ model: WorkspaceModel) -> Bool {
    pendingSave?.cancel()
    pendingSave = nil
    guard let draft, draft.isDirty else { return true }
    guard draft.conflicts.isEmpty, !draft.isUnavailable else { return false }
    // An empty title is a draft in progress, not a failed save.
    guard !draft.values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    do {
      let committed = try model.store.saveTaskEditor(draft)
      self.draft = TaskEditorDraft(snapshot: committed)
      error = nil
      persistDraft()
      model.didChange()
      return true
    } catch {
      self.error = error.localizedDescription
      refresh(model)
      return false
    }
  }

  /// Throws the draft away and returns to the saved values.
  func revert(_ model: WorkspaceModel) {
    pendingSave?.cancel()
    do {
      draft = TaskEditorDraft(snapshot: try model.store.taskEditorSnapshot(for: taskID))
      error = nil
      persistDraft()
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Writes this task's draft into the shared draft file, leaving every
  /// other task's draft as it was. Clean drafts are dropped by the store.
  private func persistDraft() {
    var drafts = (try? draftStore.load()) ?? []
    drafts.removeAll { $0.baseline.taskId == taskID }
    if let draft { drafts.append(draft) }
    try? draftStore.save(drafts)
  }

  // MARK: - Planning that is not part of the draft

  // The board column, the matrix and "planned today" live in task metadata
  // the editor snapshot does not carry, so they are written straight away as
  // their own undo steps, the way the Mac's board and matrix write them.

  func setColumn(_ column: String?, model: WorkspaceModel) {
    model.perform { try $0.setKanbanColumn(column, for: taskID) }
    loadSurroundings(model)
  }

  func setQuadrant(_ quadrant: MatrixQuadrant?, model: WorkspaceModel) {
    let position = quadrant.map {
      TaskMatrixPosition(urgency: Int($0.representativeCoordinate.urgency), importance: Int($0.representativeCoordinate.importance))
    } ?? TaskMatrixPosition(urgency: nil, importance: nil)
    model.perform { try $0.setMatrixPosition(position, for: taskID) }
    loadSurroundings(model)
  }

  var quadrant: MatrixQuadrant? {
    guard let urgency = matrix.urgency, let importance = matrix.importance,
      MatrixGeometry.isPlaced(urgency: Double(urgency), importance: Double(importance))
    else { return nil }
    return MatrixGeometry.quadrant(urgency: Double(urgency), importance: Double(importance))
  }

  func setPlanned(_ planned: Bool, model: WorkspaceModel) {
    model.perform { try $0.setPlannedForToday(planned, taskIds: [taskID]) }
    loadSurroundings(model)
  }

  /// Copies the saved conditions, start and block rules down to subtasks.
  func applyPlanningToDescendants(model: WorkspaceModel) {
    save(model)
    if model.perform({ try $0.applyPlanningToDescendants(of: taskID) }) {
      model.showToast("Applied to subtasks")
    }
  }

  // MARK: - Due, as the Mac's inspector edits it

  /// Due is one of three things: nothing, a day (`dueDate`, which stays the
  /// same calendar day across time zones), or an exact time (`dueAt`).
  enum DueKind: String, CaseIterable, Identifiable {
    case none, day, time
    var id: String { rawValue }
    var title: String {
      switch self {
      case .none: "None"
      case .day: "Day"
      case .time: "Time"
      }
    }
  }

  var dueKind: DueKind {
    if values?.dueAt != nil { return .time }
    if values?.dueDate != nil { return .day }
    return .none
  }

  func setDueKind(_ kind: DueKind, model: WorkspaceModel) {
    edit(model, immediate: true) { values in
      switch kind {
      case .none:
        values.dueAt = nil
        values.dueDate = nil
      case .day:
        values.dueDate = TaskCalendarDate.string(values.dueAt ?? .now)
        values.dueAt = nil
      case .time:
        let day = values.dueDate.flatMap { TaskCalendarDate.date($0) } ?? Calendar.current.startOfDay(for: .now)
        values.dueAt = values.dueAt ?? Calendar.current.date(byAdding: .hour, value: 17, to: day)
        values.dueDate = nil
      }
    }
  }

  // MARK: - Conditions

  func addRequirement(_ conditionID: String, toGroup index: Int? = nil, model: WorkspaceModel) {
    edit(model, immediate: true) { values in
      var groups = values.requirementGroups ?? []
      if let index, groups.indices.contains(index) {
        if !groups[index].contains(conditionID) { groups[index].append(conditionID) }
      } else {
        groups.append([conditionID])
      }
      values.requirementGroups = groups
    }
  }

  func removeRequirement(_ conditionID: String, fromGroup index: Int, model: WorkspaceModel) {
    edit(model, immediate: true) { values in
      var groups = values.requirementGroups ?? []
      guard groups.indices.contains(index) else { return }
      groups[index].removeAll { $0 == conditionID }
      groups.removeAll(where: \.isEmpty)
      values.requirementGroups = groups.isEmpty ? nil : groups
    }
  }

  func conditionName(_ id: String) -> String {
    conditions.first { $0.id == id }?.name ?? "Missing condition"
  }

  static let priorityNames = ["None", "Low", "Medium", "High", "Urgent"]

  /// A conflicting field's two values, written out for the banner.
  func display(_ field: TaskEditorField, in values: TaskEditorValues) -> String {
    switch field {
    case .title: values.title
    case .notes: values.notes.isEmpty ? "Empty" : values.notes
    case .dueAt: values.dueAt?.formatted(date: .abbreviated, time: .shortened) ?? "None"
    case .estimateMinutes: values.estimateMinutes.isEmpty ? "None" : "\(values.estimateMinutes) minutes"
    case .priority: Self.priorityNames[min(max(values.priority, 0), Self.priorityNames.count - 1)]
    case .tags: values.tags.isEmpty ? "None" : values.tags
    case .recurrenceRule: values.recurrenceRule.isEmpty ? "None" : values.recurrenceRule
    case .links: values.links.isEmpty ? "None" : values.links
    case .dailyProgress: values.dailyProgress ? "On" : "Off"
    case .startAt: values.startAt?.formatted(date: .abbreviated, time: .shortened) ?? "None"
    case .dueDate: values.dueDate ?? "None"
    case .requirements:
      (values.requirementGroups ?? []).map { $0.map(conditionName).joined(separator: " or ") }
        .joined(separator: " and ").nonEmpty ?? "None"
    case .minimumBlock: values.minimumBlockMinutes ?? "None"
    case .singleSitting: values.requiresSingleSitting == true ? "Required" : "Not required"
    }
  }
}

fileprivate extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
