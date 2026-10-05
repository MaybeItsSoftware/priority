import TaktWorkspace
import SwiftUI

/// A list scope as a Checkvist-style outline: folding in place, swipe to
/// complete, a long-press menu with every task command, drag to reorder, and
/// an inline composer for new tasks and subtasks.
struct OutlineView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  @State private var outline: OutlineModel
  @FocusState private var focusedField: Field?

  enum Field: Hashable { case composer, rename }

  init(scope: ListScope) {
    _outline = State(initialValue: OutlineModel(scope: scope))
  }

  var body: some View {
    @Bindable var navigation = model.navigation
    List(selection: $navigation.selectedTaskID) {
      if outline.composer?.anchorRowID == nil, outline.composer != nil {
        composerRow
      }
      ForEach(outline.rows) { row in
        rowView(row)
        if outline.composer?.anchorRowID == row.id {
          composerRow
        }
      }
      .onMove { source, destination in
        outline.move(from: source, to: destination, model: model)
      }
      .moveDisabled(!outline.scope.isSingleTree)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 40)
    .overlay {
      if outline.isLoaded && outline.rows.isEmpty && outline.composer == nil {
        VStack(spacing: theme.space.md) {
          EmptyState(
            title: outline.scope.isSingleTree ? "Nothing here yet" : "Nothing to do",
            message: outline.scope.isSingleTree ? "Add a task to start the list." : "Every open task in these lists shows here.",
            systemImage: "list.bullet")
          if outline.scope.isSingleTree {
            Button("Add a task") { startComposing() }
              .buttonStyle(ThemedButtonStyle(kind: .primary))
              .accessibilityIdentifier("outline.addFirst")
          }
        }
      }
    }
    .task(id: QueryKey(revision: model.revision, scope: OutlineScopeKey(scope: outline.scope, token: outline.reloadToken))) {
      await outline.load(model)
    }
    .onChange(of: model.navigation.outlineCommand) { _, command in
      guard let command else { return }
      model.navigation.outlineCommand = nil
      handle(command)
    }
    .toolbar {
      ToolbarItemGroup(placement: .secondaryAction) {
        Toggle(isOn: $outline.hidesCompleted) { Label("Hide completed", systemImage: "eye.slash") }
        if outline.scope.isSingleTree {
          Button { outline.setAllFolded(true) } label: { Label("Fold all", systemImage: "chevron.right.2") }
          Button { outline.setAllFolded(false) } label: { Label("Unfold all", systemImage: "chevron.down.2") }
        }
      }
    }
    .accessibilityIdentifier("outline.list")
  }

  // MARK: - Rows

  @ViewBuilder
  private func rowView(_ row: OutlineRow) -> some View {
    let isSelected = model.navigation.selectedTaskID == row.id
    Group {
      if outline.editingTaskID == row.id {
        renameRow(row)
      } else {
        OutlineRowView(row: row, isSelected: isSelected) { outline.toggleFold(row.id) }
          .equatable()
      }
    }
    .tag(row.id)
    .listRowInsets(EdgeInsets(top: 0, leading: theme.space.md, bottom: 0, trailing: theme.space.md))
    .listRowBackground(isSelected ? theme.primary.opacity(0.10) : theme.paper)
    .listRowSeparatorTint(theme.borderMuted)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button { model.completeCelebrating(row.id) } label: {
        Label(row.status == .open ? "Complete" : "Reopen", systemImage: row.status == .open ? "checkmark" : "arrow.uturn.backward")
      }
      .tint(theme.success)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) { model.delete(row.id) } label: { Label("Delete", systemImage: "trash") }
      Button { model.toggleInvalidated(row.id) } label: {
        Label(row.status == .cancelled ? "Reopen" : "Invalidate", systemImage: "xmark")
      }
      .tint(theme.muted)
    }
    .contextMenu {
      TaskContextMenu(
        context: menuContext(row),
        onNewChild: outline.scope.isSingleTree ? { compose { outline.composeChild(of: row) } } : nil,
        onNewAbove: outline.scope.isSingleTree ? { compose { outline.composeAbove(row) } } : nil,
        onRename: { beginRenaming(row) })
    }
    .accessibilityAction(named: row.status == .open ? "Complete" : "Reopen") { model.toggleComplete(row.id) }
    .accessibilityAction(named: row.isFolded ? "Unfold" : "Fold") { outline.toggleFold(row.id) }
  }

  private func menuContext(_ row: OutlineRow) -> TaskMenuContext {
    var context = row.menuContext
    context.allowsStructure = outline.scope.isSingleTree
    return context
  }

  private var composerRow: some View {
    let depth = outline.composer?.depth ?? 0
    return HStack(spacing: theme.space.sm) {
      TaskCheckbox(status: .open).opacity(0.4)
      TextField("New task", text: Binding(
        get: { outline.composer?.text ?? "" },
        set: { outline.composer?.text = $0 }))
        .font(theme.type.body)
        .foregroundStyle(theme.ink)
        .focused($focusedField, equals: .composer)
        .submitLabel(.next)
        .onSubmit {
          if outline.commitComposer(model) != nil {
            focusedField = .composer
          } else {
            outline.composer = nil
          }
        }
        .accessibilityIdentifier("outline.composer")
      Button {
        outline.composer = nil
        focusedField = nil
      } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(theme.dim)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Cancel new task")
    }
    .padding(.leading, CGFloat(depth) * Metrics.indent + 24)
    .frame(minHeight: theme.touchTarget)
    .listRowInsets(EdgeInsets(top: 0, leading: theme.space.md, bottom: 0, trailing: theme.space.md))
    .listRowBackground(theme.raised)
    .moveDisabled(true)
    .selectionDisabled()
  }

  private func renameRow(_ row: OutlineRow) -> some View {
    HStack(spacing: theme.space.sm) {
      TaskCheckbox(status: row.status, isList: row.isList)
      TextField("Title", text: $outline.editingText)
        .font(theme.type.body)
        .focused($focusedField, equals: .rename)
        .submitLabel(.done)
        .onSubmit { outline.commitRename(model) }
        .accessibilityIdentifier("outline.rename")
    }
    .padding(.leading, CGFloat(row.depth) * Metrics.indent + 24)
    .frame(minHeight: theme.touchTarget)
  }

  // MARK: - Commands

  private func compose(_ open: () -> Void) {
    open()
    focusedField = .composer
  }

  /// The toolbar's add button: a sibling below the selection, or a new task
  /// at the end.
  func startComposing() {
    let selected = outline.rows.first { $0.id == model.navigation.selectedTaskID }
    compose { outline.composeSibling(after: selected) }
  }

  private func beginRenaming(_ row: OutlineRow) {
    outline.beginRenaming(row)
    focusedField = .rename
  }

  private func handle(_ command: OutlineCommand) {
    let selected = outline.rows.first { $0.id == model.navigation.selectedTaskID }
    switch command {
    case .add: startComposing()
    case .addChild: if let selected { compose { outline.composeChild(of: selected) } }
    case .addAbove: if let selected { compose { outline.composeAbove(selected) } }
    case .rename: if let selected { beginRenaming(selected) }
    case .toggleFold: if let selected, selected.hasChildren { outline.toggleFold(selected.id) }
    case .expand: if let selected, selected.isFolded { outline.toggleFold(selected.id) }
    case .collapse:
      guard let selected else { return }
      if selected.hasChildren, !selected.isFolded {
        outline.toggleFold(selected.id)
      } else if let parent = selected.parentID, outline.rows.contains(where: { $0.id == parent }) {
        model.navigation.selectedTaskID = parent
      }
    case .foldAll: outline.setAllFolded(true)
    case .unfoldAll: outline.setAllFolded(false)
    case .toggleHideCompleted: outline.hidesCompleted.toggle()
    case .selectNext: select(offset: 1)
    case .selectPrevious: select(offset: -1)
    }
  }

  private func select(offset: Int) {
    let rows = outline.rows
    guard !rows.isEmpty else { return }
    guard let current = rows.firstIndex(where: { $0.id == model.navigation.selectedTaskID }) else {
      model.navigation.selectedTaskID = offset > 0 ? rows.first?.id : rows.last?.id
      return
    }
    let next = min(max(0, current + offset), rows.count - 1)
    model.navigation.selectedTaskID = rows[next].id
  }
}

/// A command for whichever outline is on screen, from the toolbar or a
/// hardware key.
enum OutlineCommand: Equatable {
  case add, addChild, addAbove, rename, toggleFold, expand, collapse, foldAll, unfoldAll, toggleHideCompleted
  case selectNext, selectPrevious
}

private struct OutlineScopeKey: Hashable {
  let scope: ListScope
  let token: Int
}

/// One outline row. Equatable on its value, so a list of five thousand rows
/// redraws only the rows whose content changed.
struct OutlineRowView: View, Equatable {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let row: OutlineRow
  let isSelected: Bool
  let onFold: () -> Void

  static func == (lhs: OutlineRowView, rhs: OutlineRowView) -> Bool {
    lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
  }

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Color.clear.frame(width: CGFloat(row.depth) * Metrics.indent, height: 1)
      disclosure
      Button {
        model.completeCelebrating(row.id)
      } label: {
        TaskCheckbox(status: row.status, isList: row.isList)
          .celebrationIcon(row.id)
          .frame(width: 32, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(row.status == .open ? "Complete \(row.title)" : "Reopen \(row.title)")
      .accessibilityIdentifier("outline.check.\(row.title)")
      VStack(alignment: .leading, spacing: 1) {
        Text(row.title)
          .font(row.isList ? theme.type.bodyMedium : theme.type.body)
          .foregroundStyle(row.status == .open ? theme.ink : theme.muted)
          .strikethrough(row.status != .open, color: theme.dim)
          .lineLimit(3)
          .celebrationStrike(row.id)
        if let listName = row.listName {
          Text(listName).font(theme.type.footnote).foregroundStyle(theme.muted).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 9)
      badges
      if isSelected {
        Button {
          model.navigation.inspect(row.id, isPad: isPad)
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(theme.primary)
            .frame(width: 32, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Details")
        .accessibilityIdentifier("outline.details")
      }
    }
    .celebrationRow(row.id)
  }

  @ViewBuilder
  private var disclosure: some View {
    if row.hasChildren {
      Button {
        withAnimation(.snappy(duration: 0.2)) { onFold() }
      } label: {
        Image(systemName: "chevron.right")
          .font(theme.type.glyph(11, .semibold))
          .foregroundStyle(theme.muted)
          .rotationEffect(.degrees(row.isFolded ? 0 : 90))
          .frame(width: 22, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(row.isFolded ? "Unfold \(row.title)" : "Fold \(row.title)")
      .accessibilityIdentifier("outline.fold.\(row.title)")
    } else {
      Color.clear.frame(width: 22, height: 1)
    }
  }

  @ViewBuilder
  private var badges: some View {
    HStack(spacing: theme.space.xs) {
      if row.isPlanned {
        Image(systemName: "sun.max").font(theme.type.glyph(12)).foregroundStyle(theme.warning)
          .accessibilityLabel("Planned for today")
      }
      if row.hasNotes {
        Image(systemName: "note.text").font(theme.type.glyph(11)).foregroundStyle(theme.dim)
      }
      if let estimate = row.estimateSeconds, estimate > 0 {
        Text(Format.duration(estimate)).font(theme.type.numeral).foregroundStyle(theme.muted)
      }
      if let due = row.dueAt {
        Tag(text: Format.due(due), tint: dueTint(due), mono: false)
      }
      if row.isList {
        Image(systemName: "list.bullet").font(theme.type.glyph(11)).foregroundStyle(theme.muted)
      }
    }
  }

  private func dueTint(_ due: Date) -> Color {
    guard row.status == .open else { return theme.muted }
    if Format.isOverdue(due) { return theme.danger }
    if Format.isToday(due) { return theme.primary }
    return theme.muted
  }
}
