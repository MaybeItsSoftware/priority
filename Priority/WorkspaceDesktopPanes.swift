import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The outline, as a view of its own. (The inspector, which was split out
/// alongside it, now lives in the right dock — `WorkspaceRightDock.swift`.)
///
/// Both used to be computed properties of `WorkspaceDesktopView`, which meant
/// the window's one body read the selection — and SwiftUI redraws a body when
/// anything it read changes, so every arrow key rebuilt the sidebar, the task
/// pane and the inspector together. Split out, a selection change reaches the
/// outline pane, which hands each row a plain `isSelected`, and only the two
/// rows whose answer changed redraw.

struct WorkspaceOutlinePane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    if model.isMultiListScope || model.selectedList != nil {
      let selectedID = model.selectedTaskID
      let tasksHaveKeyboard = model.keyboardFocusArea == .tasks
      VStack(spacing: 0) {
        WorkspacePaneHeader(title: model.currentBoardScopeTitle) {
          if let exit = model.scopeExitTitle {
            WorkspacePaneScopeExit(title: exit) { model.leaveTaskScope() }
          }
        } trailing: {
          WorkspacePaneCount(count: model.outlineOpenCount)
        }

        List {
          if model.isMultiListScope {
            // Grouped by list, because the point of a combined view is seeing
            // where each task came from. A folder shows only its own lists.
            ForEach(model.scopeLists) { list in
              Section {
                let items = model.outlineByList[list.id] ?? []
                if items.isEmpty {
                  Text("No tasks").font(theme.bodyFont()).foregroundStyle(theme.dim)
                    .padding(.horizontal, theme.paneGutter)
                    .padding(.vertical, theme.rowVerticalPadding)
                    .outlineRowChrome()
                } else {
                  ForEach(items) { item in
                    row(item, selectedID: selectedID, tasksHaveKeyboard: tasksHaveKeyboard)
                  }
                }
              } header: {
                Button(list.name) { model.selectList(list.id) }
                  .buttonStyle(.plain)
                  .font(theme.bodyFont(weight: .medium))
                  .focusable()
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(list.name)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, theme.paneGutter)
                  .padding(.top, theme.space.sm)
                  .padding(.bottom, theme.rowVerticalPadding)
                  .outlineRowChrome()
              }
            }
          } else {
            let parents = model.outlineParentIDs
            ForEach(model.outlineRows) { item in
              row(item, selectedID: selectedID, tasksHaveKeyboard: tasksHaveKeyboard,
                fold: parents.contains(item.id) ? model.foldedTaskIDs.contains(item.id) : nil)
            }
          }
        }
        // Plain rather than inset: the inset style pulls every row in from the
        // pane's edges and rounds the ends of its selection, so a chosen task
        // was a lozenge in a narrower column than its header. Plain, with the
        // row insets zeroed below, lets a row — and its selection — run the
        // full width, with the gutter laid inside it.
        .listStyle(.plain)
        // No floor under a row's height: the table's own minimum is taller
        // than a one-line row, and the difference would open a gap between
        // rows that broke the selection band and the indent guides.
        .environment(\.defaultMinListRowHeight, theme.hairline)
        // The table paints the system's own background behind the rows, which
        // left the outline the one pane not on the theme's paper.
        .scrollContentBackground(.hidden)
        .background(theme.paper)
        .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.tasks) })
      }
    } else {
      WorkspaceEmptyPane(title: "Outline", message: "Choose a list in the sidebar to see its tasks.")
    }
  }

  private func row(
    _ item: TaskOutlineItem, selectedID: String?, tasksHaveKeyboard: Bool, fold: Bool? = nil
  ) -> some View {
    let isSelected = item.id == selectedID
    return WorkspaceOutlineRow(
      item: item, isSelected: isSelected, hasKeyboard: isSelected && tasksHaveKeyboard, isFolded: fold)
      .outlineRowChrome()
  }
}

extension View {
  /// What every row of the outline's table needs to be edge to edge: no
  /// insets, no separator, no background of the table's own. The row draws
  /// its gutter and its selection itself.
  fileprivate func outlineRowChrome() -> some View {
    listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

/// One outline row, fed the answers it draws rather than the model's
/// selection, so it redraws only when its own answer changes.
struct WorkspaceOutlineRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let item: TaskOutlineItem
  let isSelected: Bool
  let hasKeyboard: Bool
  /// Whether the row's subtasks are folded away; nil when it has none.
  let isFolded: Bool?

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Button {
        if item.task.isList { model.openItemList(item.task) } else { model.toggleTask(item.task) }
      } label: {
        Image(systemName: model.itemSymbol(for: item.task))
          .foregroundStyle(item.task.status == .open ? theme.muted : theme.success)
          // A fixed column, so titles line up whichever glyph precedes them
          // and each depth's guide hangs from the middle of its parent's.
          .frame(width: WorkspaceRowMetrics.iconWidth)
      }
      .buttonStyle(.plain)
      .focusable()
      // In the space left of the glyph — the gutter, or the indent — so a row
      // with subtasks takes no more width than one without, and the guides
      // still hang from the glyphs.
      .overlay(alignment: .leading) {
        if let isFolded {
          WorkspaceFoldButton(isFolded: isFolded, title: item.task.title) { model.toggleFold(of: item.task) }
            .offset(x: -WorkspaceFoldButton.width)
        }
      }

      Button(item.task.title) {
        model.selectTask(item.task)
        model.reportKeyboardFocus(.tasks)
      }
        .buttonStyle(.plain)
        .focusable()
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.task.title)
        .strikethrough(item.task.status != .open)
        .foregroundStyle(item.task.status == .open ? theme.ink : theme.muted)
      WorkspaceTaskPlanningBadges(task: item.task).frame(maxWidth: 170, alignment: .leading)
    }
    // On the row itself: a List row takes its face from the table style, not
    // from the window, so without this every title was in the system sans.
    .font(theme.bodyFont())
    // Depth, gutter and guides all inside the row, so the selection behind it
    // runs the full width of the pane at any depth and the title column starts
    // under the header's title.
    .padding(.leading, CGFloat(item.depth) * WorkspaceRowMetrics.indent(theme))
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    .workspaceIndentGuides(
      depth: item.depth,
      origin: theme.paneGutter + WorkspaceRowMetrics.iconWidth / 2,
      step: WorkspaceRowMetrics.indent(theme))
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: item.task.id) }
    .workspaceSelection(isSelected: isSelected, hasKeyboard: hasKeyboard)
    .onTapGesture { model.selectTask(item.task) }
    .contextMenu { WorkspaceItemActions(task: item.task) }
    .onDrop(of: [WorkspaceTaskDrag.typeIdentifier], isTargeted: Binding(
      get: { model.dragDestinationListID == item.task.id },
      set: { model.dragDestinationListID = $0 ? item.task.id : nil }
    )) { providers in
      guard item.task.isList else { return false }
      return WorkspaceTaskDrag.readItemID(from: providers) { payload in
        model.moveDroppedItem(payload, toListID: item.task.listId, parentTaskID: item.task.id)
      }
    }
    .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
      .strokeBorder(
        model.dragDestinationListID == item.task.id && item.task.isList ? theme.primary : .clear,
        lineWidth: theme.borders.emphasis))
  }
}

/// The disclosure on a row with subtasks: a chevron pointing at the branch
/// when it is open, and along the row when it is folded away.
struct WorkspaceFoldButton: View {
  @Environment(\.theme) private var theme
  static let width: CGFloat = 12
  let isFolded: Bool
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: isFolded ? "chevron.right" : "chevron.down")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(theme.muted)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isFolded ? "Show the subtasks of \(title)" : "Hide the subtasks of \(title)")
    .commandHelp(.planToggleFold, note: isFolded ? "Show subtasks" : "Hide subtasks")
  }
}
