import TaktWorkspace
import SwiftUI

/// The Eisenhower matrix: four quadrants over the scope's cards, with an
/// unplaced tray beneath. Cards are placed by drag or from their menu.
struct MatrixView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @State private var matrix: MatrixModel

  init(scope: ListScope) {
    _matrix = State(initialValue: MatrixModel(scope: scope))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: theme.space.md) {
        Grid(horizontalSpacing: theme.space.sm, verticalSpacing: theme.space.sm) {
          GridRow {
            MatrixCellView(cell: .doNow, matrix: matrix, tint: theme.danger)
            MatrixCellView(cell: .schedule, matrix: matrix, tint: theme.primary)
          }
          GridRow {
            MatrixCellView(cell: .delegate, matrix: matrix, tint: theme.warning)
            MatrixCellView(cell: .eliminate, matrix: matrix, tint: theme.dim)
          }
        }
        MatrixTrayView(matrix: matrix)
      }
      .padding(theme.space.lg)
    }
    .background(theme.paper)
    .task(id: QueryKey(revision: model.revision, scope: matrix.scope)) {
      await matrix.load(model)
    }
    .accessibilityIdentifier("matrix")
  }
}

/// One quadrant: its name in its hue, and its cards.
struct MatrixCellView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  let cell: MatrixCell
  let matrix: MatrixModel
  let tint: Color
  @State private var isTargeted = false

  var body: some View {
    let cards = matrix.cards(in: cell)
    VStack(alignment: .leading, spacing: theme.space.xs) {
      HStack(spacing: theme.space.xs) {
        Circle().fill(tint).frame(width: 8, height: 8)
        Text(cell.title).font(theme.type.bodyMedium).foregroundStyle(theme.ink)
        Spacer(minLength: 0)
        Text("\(cards.count)").font(theme.type.numeral).foregroundStyle(theme.muted)
      }
      Text(cell.detail).font(theme.type.footnote).foregroundStyle(theme.muted)
      Hairline(role: .borderMuted).padding(.vertical, theme.space.xxs)
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(cards) { card in
          MatrixRow(card: card, matrix: matrix)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(theme.space.sm)
    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: theme.radius.panel, style: .continuous)
        .fill(isTargeted ? tint.opacity(0.10) : theme.raised))
    .overlay(
      RoundedRectangle(cornerRadius: theme.radius.panel, style: .continuous)
        .strokeBorder(isTargeted ? tint : theme.border, lineWidth: theme.stroke))
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      matrix.place(id, in: cell, model: model)
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityIdentifier("matrix.cell.\(cell.rawValue)")
  }
}

/// Cards the matrix has not placed yet.
struct MatrixTrayView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  let matrix: MatrixModel
  @State private var isTargeted = false

  var body: some View {
    let cards = matrix.unplaced
    VStack(alignment: .leading, spacing: theme.space.xs) {
      HStack {
        Text("Unplaced").font(theme.type.bodyMedium).foregroundStyle(theme.ink)
        Spacer()
        Text("\(cards.count)").font(theme.type.numeral).foregroundStyle(theme.muted)
      }
      Text("Drag a task into a quadrant, or long-press it to place it.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
      Hairline(role: .borderMuted).padding(.vertical, theme.space.xxs)
      if cards.isEmpty, matrix.isLoaded {
        Text("Everything is placed.").font(theme.type.callout).foregroundStyle(theme.dim)
          .frame(minHeight: 36)
      }
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(cards) { card in
          MatrixRow(card: card, matrix: matrix)
        }
      }
    }
    .padding(theme.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: theme.radius.panel, style: .continuous)
        .fill(isTargeted ? theme.hover : theme.altRow))
    .overlay(
      RoundedRectangle(cornerRadius: theme.radius.panel, style: .continuous)
        .strokeBorder(theme.border, lineWidth: theme.stroke))
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      matrix.place(id, in: nil, model: model)
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityIdentifier("matrix.tray")
  }
}

struct MatrixRow: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let card: BoardCard
  let matrix: MatrixModel

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Button { model.completeCelebrating(card.id) } label: {
        TaskCheckbox(status: card.status, isList: card.isList, size: 16)
          .celebrationIcon(card.id)
          .frame(width: 28, height: 36)
          .hitTarget()
      }
      .buttonStyle(.plain)
      .accessibilityLabel(card.status == .open ? "Complete \(card.title)" : "Reopen \(card.title)")
      Text(card.title)
        .font(theme.type.callout)
        .foregroundStyle(card.status == .open ? theme.ink : theme.muted)
        .strikethrough(card.status != .open, color: theme.dim)
        .lineLimit(2)
        .celebrationStrike(card.id)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.navigation.inspect(card.id, isPad: isPad) }
    .draggable(card.id) {
      Text(card.title).font(theme.type.callout).padding(theme.space.sm).background(theme.raised)
    }
    .contextMenu {
      ForEach(MatrixCell.allCases) { cell in
        Button { matrix.place(card.id, in: cell, model: model) } label: {
          Label(cell.title, systemImage: matrix.cell(of: card.id) == cell ? "checkmark" : "square.grid.2x2")
        }
      }
      Button { matrix.place(card.id, in: nil, model: model) } label: { Label("Unplace", systemImage: "tray") }
        .disabled(matrix.cell(of: card.id) == nil)
      TaskContextMenu(context: card.menuContext)
    }
    .accessibilityIdentifier("matrix.row.\(card.title)")
  }
}
