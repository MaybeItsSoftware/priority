import SwiftUI

/// The labelled steps undo and redo would take, newest first. Tapping a
/// step undoes (or redoes) everything up to and including it.
struct HistorySheet: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var history = StoreQuery(UndoHistory.empty)

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: theme.space.sm) {
            Button {
              model.undo()
            } label: {
              Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemedButtonStyle(kind: .quiet))
            .disabled(model.undoLabel == nil)
            .accessibilityIdentifier("history.undo")
            Button {
              model.redo()
            } label: {
              Label("Redo", systemImage: "arrow.uturn.forward").frame(maxWidth: .infinity)
            }
            .buttonStyle(ThemedButtonStyle(kind: .quiet))
            .disabled(model.redoLabel == nil)
            .accessibilityIdentifier("history.redo")
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        if !history.value.redo.isEmpty {
          Section {
            // Drawn with the next redo nearest the divider, as a stack.
            ForEach(history.value.redo.reversed()) { step in
              row(step)
            }
          } header: {
            label("Undone — tap to redo")
          }
        }
        Section {
          if history.value.undo.isEmpty {
            Text("Nothing to undo").font(theme.type.body).foregroundStyle(theme.muted)
          }
          ForEach(history.value.undo) { step in
            row(step)
          }
        } header: {
          label("Done — tap to undo back to here")
        }
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper)
      .navigationTitle("History")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .task(id: model.revision) {
        await history.load(model.store) { store in try UndoHistory.read(store) }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func label(_ text: String) -> some View {
    Text(text).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
  }

  private func row(_ step: UndoStep) -> some View {
    Button {
      if let count = history.value.undoCount(through: step) {
        for _ in 0..<count { model.undo() }
      } else if let count = history.value.redoCount(through: step) {
        for _ in 0..<count { model.redo() }
      }
    } label: {
      HStack {
        Image(systemName: step.isUndone ? "arrow.uturn.forward" : "arrow.uturn.backward")
          .foregroundStyle(step.isUndone ? theme.dim : theme.muted)
          .frame(width: 22)
        Text(step.label)
          .font(theme.type.body)
          .foregroundStyle(step.isUndone ? theme.muted : theme.ink)
        Spacer()
        if step.changeCount > 1 {
          Text("\(step.changeCount) rows").font(theme.type.numeral).foregroundStyle(theme.dim)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.raised)
    .accessibilityIdentifier("history.step.\(step.label)")
  }
}
