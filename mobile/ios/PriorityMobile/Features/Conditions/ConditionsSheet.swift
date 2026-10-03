import PriorityWorkspace
import SwiftUI

/// Manage conditions: add, rename, mark as a place, archive and restore. The
/// Mac's `WorkspaceConditionsEditor`.
///
/// Tasks name conditions by identity, so a rename here is a rename
/// everywhere and every requirement survives it. Archiving takes a condition
/// out of the pickers and the Focus chips without touching the tasks that
/// still need it — restore it and they are as they were.
struct ConditionsSheet: View {
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
            .font(Typeface.caption)
            .foregroundStyle(Palette.muted)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: Metrics.xs, bottom: 0, trailing: Metrics.xs))
        }
        Section {
          if catalogue.isLoaded, catalogue.value.active.isEmpty {
            Text("No conditions yet").font(Typeface.body).foregroundStyle(Palette.muted)
          }
          ForEach(catalogue.value.active) { condition in row(condition) }
        } header: {
          label("Available")
        }
        Section {
          HStack(spacing: Metrics.sm) {
            TextField("New condition", text: $newName)
              .font(Typeface.body)
              .focused($addFocused)
              .submitLabel(.done)
              .onSubmit(add)
              .accessibilityIdentifier("conditions.newName")
            Button {
              newIsLocation.toggle()
            } label: {
              Tag(text: "Place", tint: newIsLocation ? Palette.primary : Palette.dim, systemImage: "mappin")
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
          .listRowBackground(Palette.raised)
        } header: {
          label("Add")
        } footer: {
          Text("A place is where you are; choosing one in Focus replaces the last. Anything else — a tool, a state — can be combined.")
            .font(Typeface.footnote)
            .foregroundStyle(Palette.dim)
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
      .background(Palette.paper)
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
    Text(text).font(Typeface.caption).foregroundStyle(Palette.muted).textCase(nil)
  }

  private func row(_ condition: TaskCondition) -> some View {
    let uses = catalogue.value.usage[condition.id] ?? 0
    return Button {
      startRename(condition)
    } label: {
      HStack(spacing: Metrics.sm) {
        Image(systemName: condition.isLocation ? "mappin" : "circle.dotted")
          .foregroundStyle(condition.isArchived ? Palette.dim : Palette.purple)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text(condition.name)
            .font(Typeface.body)
            .foregroundStyle(condition.isArchived ? Palette.muted : Palette.ink)
          Text(detail(condition, uses: uses))
            .font(Typeface.footnote)
            .foregroundStyle(Palette.dim)
        }
        Spacer(minLength: 0)
        Image(systemName: "pencil").foregroundStyle(Palette.dim).imageScale(.small)
      }
      .frame(minHeight: Metrics.minimumHitTarget - 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(Palette.raised)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if condition.isArchived {
        Button { model.saveCondition(condition, isArchived: false) } label: {
          Label("Restore", systemImage: "arrow.uturn.backward")
        }
        .tint(Palette.success)
      } else {
        Button { model.saveCondition(condition, isArchived: true) } label: {
          Label("Archive", systemImage: "archivebox")
        }
        .tint(Palette.warning)
      }
    }
    .swipeActions(edge: .leading) {
      Button { model.saveCondition(condition, isLocation: !condition.isLocation) } label: {
        Label(condition.isLocation ? "Not a place" : "Place", systemImage: "mappin")
      }
      .tint(Palette.primary)
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
