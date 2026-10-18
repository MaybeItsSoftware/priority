import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// A list's outline in the focus panel: the place ⌘P goes to, walked and
/// edited without bringing the main window up or moving it.
///
/// It reads the list the way the window's outline pane reads it — the same
/// read and shaping (`panelOutline(for:)`), the same folds — and draws its
/// rows in the day's row shape, so a task looks the same here as on Today.
/// The keys are the window's (`FocusPanelKeyRouter`): ↓ from an empty field
/// hands them to the list, and then `j`/`k`, → and ←, `:12`, `dd`, `ee`,
/// `1`–`4` and Space act on the row under the panel's own cursor.
struct FocusPanelListView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let destination: QuickCaptureDestination
  let summons: FocusPanelSummons
  let onClose: (FocusPanelDismissal) -> Void
  /// Shrinks the panel back to the running block's strip; set only while a
  /// block runs.
  var onMinimise: (() -> Void)?

  @State private var query = ""
  /// The list's outline, unfolded: read when it opens and after every write.
  @State private var items: [TaskOutlineItem] = []
  @State private var selectedID: String?
  @State private var hoveredID: String?
  /// Whether the keyboard is on the rows rather than in the field.
  @State private var keysInList = false
  @State private var router = FocusPanelKeyRouter()
  @FocusState private var isFieldFocused: Bool

  private struct Row: Identifiable {
    let item: TaskOutlineItem
    let outline: DayOutlineRow
    var id: String { item.id }
  }

  var body: some View {
    let rows = rows
    VStack(spacing: 0) {
      WorkspacePaneHeader(title: destination.title) {
        if let context { Text(context) }
      } trailing: {
        FocusPanelHeaderButtons(
          onChooseList: { summons.isChoosingList = true }, onOpenWindow: openInWindow,
          onClose: { onClose(.back) })
      }
      FocusPanelRunningLine { summons.show(listID: nil) }
      FocusPanelField(
        prompt: "Filter \(destination.title), or type to add…", query: $query, isFocused: $isFieldFocused,
        help: "↓ with the field empty puts the keys in the list · ⌘P goes to another list", onKey: fieldKey)
      FocusRule()
      content(rows)
      if model.pendingTaskDeletionID != nil, let pending = model.pendingTaskDeletion {
        TaskDeletionPrompt(task: pending)
      } else {
        WorkspaceOverlayFooter(hints: hints, trailing: keysInList ? nil : "\(rows.count)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WindowKeyMonitor { handleKey($0, rows: rows) })
    .onAppear {
      reload()
      reset()
    }
    .onChange(of: summons.count) { _, _ in reset() }
    .onChange(of: destination.id) { _, _ in
      reload()
      selectedID = nil
      reset()
    }
    .onChange(of: model.taskContentRevision) { _, _ in reload() }
    .onChange(of: rows.map(\.outline)) { old, _ in keepCursor(previous: old) }
    .onChange(of: selectedID) { _, _ in model.cancelPendingTaskDeletion() }
    .onChange(of: query) { _, _ in
      model.cancelPendingTaskDeletion()
      keepCursor(previous: [])
    }
    // An edit put away hands the keyboard back to where it was.
    .onChange(of: model.panelOverlay == nil) { _, closed in
      if closed && !keysInList { isFieldFocused = true }
    }
    // The caret back in the field, by a click or otherwise, is typing again.
    .onChange(of: isFieldFocused) { _, focused in
      if focused && keysInList {
        keysInList = false
        router.reset()
      }
    }
  }

  /// Where a nested list sits, or a list's folder.
  private var context: String? {
    guard destination.parentTaskID != nil else {
      let folderID = model.lists.first { $0.id == destination.listID }?.folderId
      return folderID.flatMap { id in model.folders.first { $0.id == id }?.name }
    }
    let parents = destination.path.components(separatedBy: " › ").dropLast()
    return parents.isEmpty ? nil : parents.joined(separator: " › ")
  }

  private var hints: String {
    if let jump = router.numberJumpHint { return jump }
    if keysInList {
      return "space done · ee dd ⌥t edit · 1–4 priority · cc needs · / filter · esc \(onMinimise == nil ? "hide" : "minimise")"
    }
    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return "↑↓ choose · ↩ add · ⇥ start · ⌘D due · F2 title · esc clear"
    }
    return "↓ the list · ⌘P lists · ⌘T today · esc \(onMinimise == nil ? "hide" : "minimise")"
  }

  // MARK: - The rows

  /// With the field empty, the outline as drawn — folds applied, and each
  /// row knowing what hangs beneath it. Typed into, every task in the list
  /// whose title matches, flat, best first.
  private var rows: [Row] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard needle.isEmpty else {
      let scored: [(TaskOutlineItem, Int)] = items.compactMap { item in
        WorkspaceCommandQuery.fuzzyScore(needle, in: item.task.title).map { (item, $0) }
      }
      return scored.enumerated()
        .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
        .map { entry in
          let item = entry.element.0
          return Row(
            item: TaskOutlineItem(task: item.task, depth: 0),
            outline: DayOutlineRow(id: item.id, depth: 0, parentID: nil, hasChildren: false, isUnfolded: false))
        }
    }
    let folded = model.foldedTaskIDs
    let visible = TaskOutlineFolding.visible(items, folded: folded)
    let outline = TaskOutlineFolding.dayOutlineRows(
      visible, parents: TaskOutlineFolding.parentIDs(items), folded: folded)
    return zip(visible, outline).map { Row(item: $0, outline: $1) }
  }

  @ViewBuilder
  private func content(_ rows: [Row]) -> some View {
    if rows.isEmpty {
      VStack(spacing: theme.space.xs) {
        Spacer()
        Text(query.isEmpty ? "Nothing in \(destination.title)" : "No matches")
          .font(theme.bodyFont())
          .foregroundStyle(theme.muted)
        Text(query.isEmpty
          ? "Type a title and press Return to add one."
          : "Return adds “\(query.trimmingCharacters(in: .whitespaces))” to \(destination.title).")
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, theme.space.xl)
    } else {
      let numbering = router.numberJump != nil
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              view(for: row, number: numbering ? index + 1 : nil)
                .id(row.id)
            }
          }
          .padding(.bottom, theme.space.sm)
        }
        .onChange(of: selectedID) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  private func view(for row: Row, number: Int?) -> some View {
    let task = row.item.task
    let isActive = task.id == model.activeFocusSession?.activeTaskId
    let isDaily = model.isDailyProgressTask(task)
    let facts = DayTaskFacts(
      task: task, index: number, isActive: isActive, completion: .workspaceTask(id: task.id),
      isDaily: isDaily, isDailyDone: isDaily && model.isDailyProgressComplete(task),
      priority: model.taskPriorities[task.id],
      cost: DayTaskFacts.cost(estimate: task.estimateSeconds, logged: model.taskLoggedSeconds[task.id] ?? 0),
      // Done, cancelled or waiting on another task: greyed, as the outline
      // greys them.
      isBlocked: task.status != .open || model.isBlocked(task))
    let chrome = DayRowChrome(
      id: task.id, isPanel: true, isSelected: task.id == selectedID, hasKeyboard: false,
      isHovered: hoveredID == task.id, isActive: isActive, completion: .workspaceTask(id: task.id),
      depth: row.outline.depth, fold: row.outline.hasChildren ? !row.outline.isUnfolded : nil)
    return DayTaskRow(
      facts: facts, listName: nil,
      detail: task.dueAt.map { "Due \(RelativeDateTextCache.shared.text(for: $0))" },
      chrome: chrome,
      onHover: { inside in
        if inside { hoveredID = task.id } else if hoveredID == task.id { hoveredID = nil }
      },
      onTap: { selectedID = task.id },
      onTick: { complete(task) },
      onFold: { setFolded(task.id, !model.foldedTaskIDs.contains(task.id)) })
      .equatable()
  }

  // MARK: - Reading and the cursor

  private func reload() {
    let read = model.panelOutline(for: destination)
    if read != items { items = read }
  }

  /// A fresh summon: an empty field with the caret in it, and the cursor
  /// where it was if that row is still here.
  private func reset() {
    query = ""
    keysInList = false
    router.reset()
    isFieldFocused = true
    let ids = rows.map(\.id)
    if selectedID.map(ids.contains) != true { selectedID = ids.first }
  }

  /// A row that left — ticked off, moved, folded away — hands the cursor to
  /// its neighbour or parent, as everywhere else.
  private func keepCursor(previous: [DayOutlineRow]) {
    let ids = rows.map(\.id)
    if let selectedID, ids.contains(selectedID) { return }
    let successor = selectedID.flatMap { DayOutline.successor(of: $0, previous: previous, remaining: ids) }
    selectedID = successor ?? ids.first
  }

  private func move(by offset: Int) {
    let ids = rows.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
    selectedID = ids[min(max(0, current + offset), ids.count - 1)]
  }

  private func setFolded(_ id: String, _ folded: Bool) {
    guard let task = model.task(withID: id) else { return }
    WorkspaceMotion.animate { model.setFolded(task, folded) }
  }

  // MARK: - Keys

  private func context(_ rows: [Row]) -> FocusPanelListContext {
    let ids = rows.map(\.id)
    let outline = rows.map(\.outline)
    return FocusPanelListContext(
      surface: .outline, rowIDs: ids, numberedIDs: ids, cursorID: selectedID,
      setCursor: { selectedID = $0 },
      right: {
        guard let id = selectedID else { selectedID = ids.first; return }
        switch DayOutline.right(from: id, in: outline) {
        case .unfold(let id): setFolded(id, false)
        case .select(let child): selectedID = child
        case .fold, .leave: break
        }
      },
      left: {
        guard let id = selectedID else { summons.isChoosingList = true; return }
        switch DayOutline.left(from: id, in: outline) {
        case .fold(let id): setFolded(id, true)
        case .select(let parent): selectedID = parent
        // Out of the list, as ← out of a list in the window goes to the
        // sidebar: here, the list switcher.
        case .unfold, .leave: summons.isChoosingList = true
        }
      },
      complete: complete, start: start,
      confirmDeletion: { model.confirmPendingTaskDeletion() },
      toField: {
        keysInList = false
        router.reset()
        isFieldFocused = true
      },
      dismiss: dismiss, openInWindow: openInWindow)
  }

  private func handleKey(_ event: NSEvent, rows: [Row]) -> Bool {
    guard !summons.isChoosingList else { return false }
    if keysInList {
      return router.handleListKey(event, model: model, summons: summons, context: context(rows))
    }
    return router.handleFieldKey(event, model: model, summons: summons, context: context(rows))
  }

  private func fieldKey(_ key: FocusPanelFieldKey) -> KeyPress.Result {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    switch key {
    case .up, .down:
      move(by: key == .up ? -1 : 1)
      // With nothing typed there is nothing to refine, so the keys go to the
      // rows: the window's keys work from here.
      if query.isEmpty {
        keysInList = true
        isFieldFocused = false
      }
      return .handled
    case .left:
      return .ignored
    case .escape:
      if model.pendingTaskDeletionID != nil {
        model.cancelPendingTaskDeletion()
      } else if !query.isEmpty {
        query = ""
      } else {
        dismiss()
      }
      return .handled
    case .commandDelete:
      guard query.isEmpty, let task = selectedID.flatMap(model.task(withID:)),
        task.id != model.activeFocusSession?.activeTaskId
      else { return .ignored }
      model.requestTaskDeletion(task)
      return .handled
    case .enter:
      if model.pendingTaskDeletionID != nil {
        model.confirmPendingTaskDeletion()
      } else if !trimmed.isEmpty, let task = model.createTask(capturing: trimmed, in: destination) {
        query = ""
        selectedID = task.id
      }
      return .handled
    case .commandEnter:
      openInWindow()
      return .handled
    case .space:
      guard query.isEmpty, model.pendingTaskDeletionID == nil,
        let task = selectedID.flatMap(model.task(withID:))
      else { return .ignored }
      complete(task)
      return .handled
    case .tab:
      if let task = selectedID.flatMap(model.task(withID:)) { start(task) }
      return .handled
    }
  }

  // MARK: - Acting

  /// Space, as in the window's outline: done or open again. The running task
  /// finishes through its block, so its minutes are kept.
  private func complete(_ task: WorkspaceTask) {
    if task.id == model.activeFocusSession?.activeTaskId {
      model.requestFocusCompletion(from: .panel)
    } else if model.isDailyProgressTask(task) {
      if !model.isDailyProgressComplete(task) { model.toggleDailyProgress(task) }
    } else {
      model.toggleTask(task)
    }
  }

  /// A list row is a place to go rather than something to run: Tab opens it
  /// in the panel.
  private func start(_ task: WorkspaceTask) {
    if task.isList {
      summons.show(listID: task.id)
    } else {
      model.startOrQueueFocus(on: task, from: .panel)
    }
  }

  private func dismiss() {
    if let onMinimise { onMinimise() } else { onClose(.back) }
  }

  private func openInWindow() {
    onClose(.toWindow)
    AppDelegate.shared.showMainWindow()
    if destination.parentTaskID != nil, let list = model.task(withID: destination.id) {
      model.selectNestedList(list)
    } else {
      model.selectList(destination.listID)
    }
    if let task = selectedID.flatMap(model.task(withID:)) {
      model.unfoldAncestors(of: task)
      model.selectTask(task)
    }
  }
}
