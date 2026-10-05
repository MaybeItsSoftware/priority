import TaktWorkspace
import SwiftUI

/// Manage conditions: add, rename, mark as a place, archive and restore. The
/// Mac's `WorkspaceConditionsEditor`.
///
/// Tasks name conditions by identity, so a rename here is a rename
/// everywhere and every requirement survives it. Archiving takes a condition
/// out of the pickers and the Focus chips without touching the tasks that
/// still need it — restore it and they are as they were.
struct ConditionsSheet: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var catalogue = StoreQuery(ConditionsCatalogue.empty)
  @State private var newName = ""
  @State private var newIsLocation = false
  @State private var renaming: TaskCondition?
  @State private var renameText = ""
  @FocusState private var addFocused: Bool

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Tasks refer to conditions by identity. Renaming one keeps every requirement on it intact.")
            .font(theme.type.caption)
            .foregroundStyle(theme.muted)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: theme.space.xs, bottom: 0, trailing: theme.space.xs))
        }
        Section {
          if catalogue.isLoaded, catalogue.value.active.isEmpty {
            Text("No conditions yet").font(theme.type.body).foregroundStyle(theme.muted)
          }
          ForEach(catalogue.value.active) { condition in row(condition) }
        } header: {
          label("Available")
        }
        Section {
          HStack(spacing: theme.space.sm) {
            TextField("New condition", text: $newName)
              .font(theme.type.body)
              .focused($addFocused)
              .submitLabel(.done)
              .onSubmit(add)
              .accessibilityIdentifier("conditions.newName")
            Button {
              newIsLocation.toggle()
            } label: {
              Tag(text: "Place", tint: newIsLocation ? theme.primary : theme.dim, systemImage: "mappin")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Place")
            .accessibilityValue(newIsLocation ? "On" : "Off")
            .accessibilityIdentifier("conditions.newIsLocation")
            Button("Add", action: add)
              .buttonStyle(ThemedButtonStyle(kind: .primary, compact: true))
              .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("conditions.add")
          }
          .listRowBackground(theme.raised)
        } header: {
          label("Add")
        } footer: {
          Text("A place is where you are; choosing one in Focus replaces the last. Anything else — a tool, a state — can be combined.")
            .font(theme.type.footnote)
            .foregroundStyle(theme.dim)
        }
        if !catalogue.value.archived.isEmpty {
          Section {
            ForEach(catalogue.value.archived) { condition in row(condition) }
          } header: {
            label("Archived")
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper)
      .navigationTitle("Conditions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("conditions.done")
        }
      }
      .task(id: model.revision) {
        let workspaceID = model.workspace.id
        await catalogue.load(model.store) { store in try ConditionsCatalogue.load(store: store, workspaceID: workspaceID) }
      }
      .alert("Rename condition", isPresented: renameBinding, presenting: renaming) { condition in
        TextField("Name", text: $renameText)
        Button("Cancel", role: .cancel) { renaming = nil }
        Button("Rename") {
          let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
          if !name.isEmpty, name != condition.name { model.saveCondition(condition, name: name) }
          renaming = nil
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var renameBinding: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private func label(_ text: String) -> some View {
    Text(text).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
  }

  private func row(_ condition: TaskCondition) -> some View {
    let uses = catalogue.value.usage[condition.id] ?? 0
    return Button {
      startRename(condition)
    } label: {
      HStack(spacing: theme.space.sm) {
        Image(systemName: condition.isLocation ? "mappin" : "circle.dotted")
          .foregroundStyle(condition.isArchived ? theme.dim : theme.purple)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text(condition.name)
            .font(theme.type.body)
            .foregroundStyle(condition.isArchived ? theme.muted : theme.ink)
          Text(detail(condition, uses: uses))
            .font(theme.type.footnote)
            .foregroundStyle(theme.dim)
        }
        Spacer(minLength: 0)
        Image(systemName: "pencil").foregroundStyle(theme.dim).imageScale(.small)
      }
      .frame(minHeight: theme.touchTarget - 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.raised)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if condition.isArchived {
        Button { model.saveCondition(condition, isArchived: false) } label: {
          Label("Restore", systemImage: "arrow.uturn.backward")
        }
        .tint(theme.success)
      } else {
        Button { model.saveCondition(condition, isArchived: true) } label: {
          Label("Archive", systemImage: "archivebox")
        }
        .tint(theme.warning)
      }
    }
    .swipeActions(edge: .leading) {
      Button { model.saveCondition(condition, isLocation: !condition.isLocation) } label: {
        Label(condition.isLocation ? "Not a place" : "Place", systemImage: "mappin")
      }
      .tint(theme.primary)
    }
    .contextMenu {
      Button { startRename(condition) } label: { Label("Rename", systemImage: "pencil") }
      Button { model.saveCondition(condition, isLocation: !condition.isLocation) } label: {
        Label(condition.isLocation ? "Not a place" : "Mark as a place", systemImage: "mappin")
      }
      if condition.isArchived {
        Button { model.saveCondition(condition, isArchived: false) } label: {
          Label("Restore", systemImage: "arrow.uturn.backward")
        }
      } else {
        Button { model.saveCondition(condition, isArchived: true) } label: {
          Label("Archive", systemImage: "archivebox")
        }
      }
    }
    .accessibilityIdentifier("conditions.row.\(condition.name)")
    .accessibilityActions {
      Button(condition.isArchived ? "Restore" : "Archive") {
        model.saveCondition(condition, isArchived: !condition.isArchived)
      }
      Button(condition.isLocation ? "Not a place" : "Mark as a place") {
        model.saveCondition(condition, isLocation: !condition.isLocation)
      }
    }
  }

  private func detail(_ condition: TaskCondition, uses: Int) -> String {
    var parts = [condition.isLocation ? "Place" : "Capability"]
    parts.append(uses == 0 ? "No tasks" : uses == 1 ? "1 task" : "\(uses) tasks")
    if condition.isArchived { parts.append("Archived") }
    return parts.joined(separator: " · ")
  }

  private func startRename(_ condition: TaskCondition) {
    renameText = condition.name
    renaming = condition
  }

  private func add() {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if model.createCondition(named: name, isLocation: newIsLocation) != nil {
      newName = ""
      newIsLocation = false
    }
  }
}
