import PriorityWorkspace
import SwiftUI

/// The Eisenhower matrix: four quadrants over the scope's cards, with an
/// unplaced tray beneath. Cards are placed by drag or from their menu.
struct MatrixView: View {
  @Environment(WorkspaceModel.self) private var model
  @State private var matrix: MatrixModel

  init(scope: ListScope) {
    _matrix = State(initialValue: MatrixModel(scope: scope))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Metrics.md) {
        Grid(horizontalSpacing: Metrics.sm, verticalSpacing: Metrics.sm) {
          GridRow {
            MatrixCellView(cell: .doNow, matrix: matrix, tint: Palette.danger)
            MatrixCellView(cell: .schedule, matrix: matrix, tint: Palette.primary)
          }
          GridRow {
            MatrixCellView(cell: .delegate, matrix: matrix, tint: Palette.warning)
            MatrixCellView(cell: .eliminate, matrix: matrix, tint: Palette.dim)
          }
        }
        MatrixTrayView(matrix: matrix)
      }
      .padding(Metrics.lg)
    }
    .background(Palette.paper)
    .task(id: QueryKey(revision: model.revision, scope: matrix.scope)) {
      await matrix.load(model)
    }
    .accessibilityIdentifier("matrix")
  }
}

/// One quadrant: its name in its hue, and its cards.
struct MatrixCellView: View {
  @Environment(WorkspaceModel.self) private var model
  let cell: MatrixCell
  let matrix: MatrixModel
  let tint: Color
  @State private var isTargeted = false

  var body: some View {
    let cards = matrix.cards(in: cell)
    VStack(alignment: .leading, spacing: Metrics.xs) {
      HStack(spacing: Metrics.xs) {
        Circle().fill(tint).frame(width: 8, height: 8)
        Text(cell.title).font(Typeface.bodyMedium).foregroundStyle(Palette.ink)
        Spacer(minLength: 0)
        Text("\(cards.count)").font(Typeface.numeral).foregroundStyle(Palette.muted)
      }
      Text(cell.detail).font(Typeface.footnote).foregroundStyle(Palette.muted)
      Hairline(color: Palette.borderMuted).padding(.vertical, Metrics.xxs)
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(cards) { card in
          MatrixRow(card: card, matrix: matrix)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Metrics.sm)
    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .fill(isTargeted ? tint.opacity(0.10) : Palette.raised))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .strokeBorder(isTargeted ? tint : Palette.border, lineWidth: 1))
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
  @Environment(WorkspaceModel.self) private var model
  let matrix: MatrixModel
  @State private var isTargeted = false

  var body: some View {
    let cards = matrix.unplaced
    VStack(alignment: .leading, spacing: Metrics.xs) {
      HStack {
        Text("Unplaced").font(Typeface.bodyMedium).foregroundStyle(Palette.ink)
        Spacer()
        Text("\(cards.count)").font(Typeface.numeral).foregroundStyle(Palette.muted)
      }
      Text("Drag a task into a quadrant, or long-press it to place it.")
        .font(Typeface.footnote).foregroundStyle(Palette.muted)
      Hairline(color: Palette.borderMuted).padding(.vertical, Metrics.xxs)
      if cards.isEmpty, matrix.isLoaded {
        Text("Everything is placed.").font(Typeface.callout).foregroundStyle(Palette.dim)
          .frame(minHeight: 36)
      }
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(cards) { card in
          MatrixRow(card: card, matrix: matrix)
        }
      }
    }
    .padding(Metrics.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .fill(isTargeted ? Palette.hover : Palette.altRow))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        .strokeBorder(Palette.border, lineWidth: 1))
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      matrix.place(id, in: nil, model: model)
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityIdentifier("matrix.tray")
  }
}

struct MatrixRow: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let card: BoardCard
  let matrix: MatrixModel

  var body: some View {
    HStack(spacing: Metrics.xs) {
      Button { model.completeCelebrating(card.id) } label: {
        TaskCheckbox(status: card.status, isList: card.isList, size: 16)
          .celebrationIcon(card.id)
          .frame(width: 28, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(card.status == .open ? "Complete \(card.title)" : "Reopen \(card.title)")
      Text(card.title)
        .font(Typeface.callout)
        .foregroundStyle(card.status == .open ? Palette.ink : Palette.muted)
        .strikethrough(card.status != .open, color: Palette.dim)
        .lineLimit(2)
        .celebrationStrike(card.id)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.navigation.inspect(card.id, isPad: isPad) }
    .draggable(card.id) {
      Text(card.title).font(Typeface.callout).padding(Metrics.sm).background(Palette.raised)
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
