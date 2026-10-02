import PriorityWorkspace
import SwiftUI

/// The scope's kanban board: paging columns of cards, each card carrying its
/// foldable subtasks. Cards move by drag or by menu; columns can be added,
/// renamed, reordered and removed.
struct BoardView: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  @State private var board: BoardModel
  @State private var columnPrompt: ColumnPrompt?
  @State private var promptText = ""
  @State private var pendingRemoval: WorkspaceKanbanColumn?
  @FocusState private var composerFocused: Bool

  enum ColumnPrompt: Identifiable, Equatable {
    case add
    case rename(WorkspaceKanbanColumn)
    var id: String {
      switch self {
      case .add: "add"
      case .rename(let column): "rename-\(column.id)"
      }
    }
  }

  init(scope: ListScope) {
    _board = State(initialValue: BoardModel(scope: scope))
  }

  var body: some View {
    GeometryReader { proxy in
      let width = columnWidth(for: proxy.size.width)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: Metrics.md) {
          ForEach(board.columns) { column in
            BoardColumnView(
              column: column, cards: board.cards(in: column.id), board: board, width: width,
              composerFocused: $composerFocused,
              onRename: { promptText = column.title; columnPrompt = .rename(column) },
              onRemove: { pendingRemoval = column })
          }
          addColumnButton
            .frame(width: min(width, 200))
        }
        .scrollTargetLayout()
        .padding(.horizontal, Metrics.lg)
        .padding(.vertical, Metrics.md)
      }
      .scrollTargetBehavior(.viewAligned)
      .scrollIndicators(.hidden)
    }
    .background(Palette.paper)
    .task(id: QueryKey(revision: model.revision, scope: board.scope)) {
      await board.load(model)
    }
    .alert(columnPromptTitle, isPresented: promptBinding, presenting: columnPrompt) { prompt in
      TextField("Column name", text: $promptText)
        .accessibilityIdentifier("board.columnName")
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        switch prompt {
        case .add: board.addColumn(named: promptText, model: model)
        case .rename(let column): board.renameColumn(column.id, to: promptText, model: model)
        }
      }
    }
    .confirmationDialog(
      pendingRemoval.map { "Remove \($0.title)?" } ?? "", isPresented: removalBinding, titleVisibility: .visible,
      presenting: pendingRemoval
    ) { column in
      Button("Remove column", role: .destructive) { board.removeColumn(column.id, model: model) }
    } message: { _ in
      Text("Its cards move to the first remaining column. You can undo it.")
    }
    .accessibilityIdentifier("board")
  }

  /// One column fills an iPhone (less a peek of the next); an iPad shows
  /// several side by side.
  private func columnWidth(for width: CGFloat) -> CGFloat {
    let available = width - Metrics.lg * 2
    if available < 500 { return max(240, available - 28) }
    return min(340, max(260, (available - Metrics.md * 2) / 3))
  }

  private var addColumnButton: some View {
    Button {
      promptText = ""
      columnPrompt = .add
    } label: {
      Label("Add column", systemImage: "plus")
        .font(Typeface.callout)
        .foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, minHeight: 44)
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("board.addColumn")
  }

  private var columnPromptTitle: String {
    if case .rename = columnPrompt { return "Rename column" }
    return "New column"
  }

  private var promptBinding: Binding<Bool> {
    Binding(get: { columnPrompt != nil }, set: { if !$0 { columnPrompt = nil } })
  }

  private var removalBinding: Binding<Bool> {
    Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
  }
}

/// One column: its header, its cards, and an inline add field.
struct BoardColumnView: View {
  @Environment(WorkspaceModel.self) private var model
  let column: WorkspaceKanbanColumn
  let cards: [BoardCard]
  let board: BoardModel
  let width: CGFloat
  var composerFocused: FocusState<Bool>.Binding
  let onRename: () -> Void
  let onRemove: () -> Void
  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline(color: Palette.borderMuted)
      ScrollView(.vertical) {
        LazyVStack(spacing: Metrics.sm) {
          ForEach(cards) { card in
            BoardCardView(card: card, board: board, column: column)
          }
          composer
        }
        .padding(Metrics.sm)
      }
      .scrollIndicators(.hidden)
    }
    .frame(width: width)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(isTargeted ? Palette.primary.opacity(0.06) : Palette.altRow)
    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .strokeBorder(isTargeted ? Palette.primary : Palette.border, lineWidth: isTargeted ? 1.5 : 1))
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first, board.snapshot.allCards.contains(where: { $0.id == id }) else { return false }
      board.move(id, toColumn: column.id, model: model)
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityIdentifier("board.column.\(column.title)")
  }

  private var header: some View {
    HStack(spacing: Metrics.sm) {
      Text(column.title)
        .font(Typeface.bodyMedium)
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
      Text("\(cards.count)")
        .font(Typeface.numeral)
        .foregroundStyle(Palette.muted)
      Spacer(minLength: 0)
      Button {
        board.composerText = ""
        board.composingColumnID = column.id
        composerFocused.wrappedValue = true
      } label: {
        Image(systemName: "plus").frame(width: 32, height: 36).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.muted)
      .accessibilityLabel("Add a card to \(column.title)")
      .accessibilityIdentifier("board.add.\(column.title)")
      Menu {
        Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
        Button { board.moveColumn(column.id, by: -1, model: model) } label: { Label("Move left", systemImage: "arrow.left") }
          .disabled(board.columns.first?.id == column.id)
        Button { board.moveColumn(column.id, by: 1, model: model) } label: { Label("Move right", systemImage: "arrow.right") }
          .disabled(board.columns.last?.id == column.id)
        Divider()
        Button(role: .destructive) { onRemove() } label: { Label("Remove column…", systemImage: "trash") }
          .disabled(board.columns.count <= 1)
      } label: {
        Image(systemName: "ellipsis").frame(width: 32, height: 36).contentShape(Rectangle())
      }
      .foregroundStyle(Palette.muted)
      .accessibilityLabel("\(column.title) options")
    }
    .padding(.leading, Metrics.md)
    .padding(.trailing, Metrics.xs)
    .frame(minHeight: 44)
  }

  @ViewBuilder
  private var composer: some View {
    if board.composingColumnID == column.id {
      HStack(spacing: Metrics.sm) {
        TextField("New card", text: Binding(get: { board.composerText }, set: { board.composerText = $0 }))
          .font(Typeface.body)
          .focused(composerFocused)
          .submitLabel(.next)
          .onSubmit {
            if board.addCard(board.composerText, toColumn: column.id, model: model) != nil {
              board.composerText = ""
              composerFocused.wrappedValue = true
            } else {
              board.composingColumnID = nil
            }
          }
          .accessibilityIdentifier("board.composer")
        Button {
          board.composingColumnID = nil
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.dim)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel new card")
      }
      .padding(Metrics.md)
      .cardSurface()
    }
  }
}

/// One card. Equatable on its value so an unchanged card is not redrawn.
struct BoardCardView: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let card: BoardCard
  let board: BoardModel
  let column: WorkspaceKanbanColumn
  @State private var isTargeted = false

  private var isSelected: Bool { model.navigation.selectedTaskID == card.id }

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.xs) {
      if let parentTitle = card.parentTitle {
        Text(parentTitle).font(Typeface.footnote).foregroundStyle(Palette.muted).lineLimit(1)
      }
      HStack(alignment: .top, spacing: Metrics.sm) {
        Button { model.toggleComplete(card.id) } label: {
          TaskCheckbox(status: card.status, isList: card.isList)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.status == .open ? "Complete \(card.title)" : "Reopen \(card.title)")
        Text(card.title)
          .font(card.isList ? Typeface.bodyMedium : Typeface.body)
          .foregroundStyle(card.status == .open ? Palette.ink : Palette.muted)
          .strikethrough(card.status != .open, color: Palette.dim)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 3)
        if !card.subtasks.isEmpty {
          foldButton(card.id, title: card.title, folded: board.folded.contains(card.id))
        }
      }
      badges
      subtasks
    }
    .padding(Metrics.sm)
    .background(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .fill(isSelected ? Palette.primary.opacity(0.08) : Palette.raised))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .strokeBorder(isSelected || isTargeted ? Palette.primary : Palette.border, lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    .onTapGesture { model.navigation.inspect(card.id, isPad: isPad) }
    .draggable(card.id) {
      Text(card.title).font(Typeface.body).padding(Metrics.sm).background(Palette.raised)
    }
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first, id != card.id, board.snapshot.allCards.contains(where: { $0.id == id }) else {
        return false
      }
      board.move(id, before: card.id, model: model)
      return true
    } isTargeted: { isTargeted = $0 }
    .contextMenu {
      Menu {
        ForEach(board.columns) { other in
          Button(other.title) { board.move(card.id, toColumn: other.id, model: model) }
            .disabled(other.id == column.id)
        }
      } label: { Label("Move to column", systemImage: "rectangle.split.3x1") }
      Button { board.moveToAdjacentColumn(card.id, by: -1, model: model) } label: {
        Label("Move left", systemImage: "arrow.left")
      }
      .disabled(board.columns.first?.id == column.id)
      Button { board.moveToAdjacentColumn(card.id, by: 1, model: model) } label: {
        Label("Move right", systemImage: "arrow.right")
      }
      .disabled(board.columns.last?.id == column.id)
      TaskContextMenu(context: card.menuContext)
    }
    .accessibilityIdentifier("board.card.\(card.title)")
  }

  @ViewBuilder
  private var badges: some View {
    let hasBadges = card.isPlanned || card.dueAt != nil || (card.estimateSeconds ?? 0) > 0 || card.listName != nil
    if hasBadges {
      HStack(spacing: Metrics.xs) {
        if card.isPlanned {
          Image(systemName: "sun.max").font(.system(size: 12)).foregroundStyle(Palette.warning)
        }
        if let estimate = card.estimateSeconds, estimate > 0 {
          Text(Format.duration(estimate)).font(Typeface.numeral).foregroundStyle(Palette.muted)
        }
        if let due = card.dueAt {
          Tag(
            text: Format.due(due),
            tint: card.status != .open ? Palette.muted
              : Format.isOverdue(due) ? Palette.danger : Format.isToday(due) ? Palette.primary : Palette.muted)
        }
        Spacer(minLength: 0)
        if let listName = card.listName {
          Text(listName).font(Typeface.footnote).foregroundStyle(Palette.muted).lineLimit(1)
        }
      }
      .padding(.leading, 36)
    }
  }

  @ViewBuilder
  private var subtasks: some View {
    let rows = board.subtaskRows(of: card)
    if !rows.isEmpty {
      let parents = board.subtaskParentIDs(of: card)
      let shown = rows.prefix(BoardModel.visibleSubtaskRows)
      VStack(alignment: .leading, spacing: 0) {
        Hairline(color: Palette.borderMuted).padding(.vertical, Metrics.xxs)
        ForEach(Array(shown), id: \.id) { item in
          HStack(spacing: Metrics.xs) {
            Color.clear.frame(width: CGFloat(item.depth) * Metrics.indent, height: 1)
            Button { model.toggleComplete(item.id) } label: {
              TaskCheckbox(status: item.task.status, isList: item.task.isList, size: 16)
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.task.status == .open ? "Complete \(item.task.title)" : "Reopen \(item.task.title)")
            Text(item.task.title)
              .font(Typeface.callout)
              .foregroundStyle(item.task.status == .open ? Palette.ink : Palette.muted)
              .strikethrough(item.task.status != .open, color: Palette.dim)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
              .onTapGesture { model.navigation.inspect(item.id, isPad: isPad) }
            if parents.contains(item.id) {
              foldButton(item.id, title: item.task.title, folded: board.folded.contains(item.id))
            }
          }
          .contextMenu {
            TaskContextMenu(context: TaskMenuContext(
              taskID: item.id, title: item.task.title, status: item.task.status, isList: item.task.isList,
              isPromoted: item.task.isPromoted == true, isPlanned: false, allowsStructure: false))
          }
        }
        if rows.count > shown.count {
          Button("+\(rows.count - shown.count) more") { model.navigation.inspect(card.id, isPad: isPad) }
            .font(Typeface.footnote)
            .foregroundStyle(Palette.muted)
            .buttonStyle(.plain)
            .padding(.leading, 32)
            .frame(minHeight: 28)
        }
      }
      .padding(.leading, 4)
    }
  }

  private func foldButton(_ id: String, title: String, folded: Bool) -> some View {
    Button {
      withAnimation(.snappy(duration: 0.2)) { board.toggleFold(id) }
    } label: {
      Image(systemName: "chevron.right")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Palette.muted)
        .rotationEffect(.degrees(folded ? 0 : 90))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(folded ? "Unfold \(title)" : "Fold \(title)")
  }
}
