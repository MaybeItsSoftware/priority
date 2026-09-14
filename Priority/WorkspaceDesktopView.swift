import PriorityWorkspace
import SwiftUI

struct WorkspaceDesktopView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var floatingTimer = LocalFloatingFocusTimer()

  var body: some View {
    HSplitView {
      sidebar
        .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
      taskPane
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      inspector
        .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
    }
    .frame(minWidth: 760, minHeight: 520)
    .alert("Priority needs attention", isPresented: Binding(
      get: { model.errorMessage != nil },
      set: { if !$0 { model.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    .sheet(isPresented: Bindable(model).showsFocusPanel) {
      LocalFocusPanel(onFloat: {
        floatingTimer.show(model: model)
        model.showsFocusPanel = false
      })
        .environment(model)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PRIORITY")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)

      Label("Home", systemImage: "house")
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)

      Text("LISTS")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)

      List(selection: Binding(
        get: { model.selectedListID },
        set: { if let id = $0 { model.selectList(id) } }
      )) {
        let rootLists = model.lists.filter { $0.folderId == nil }
        ForEach(model.folders) { folder in
          Section {
            ForEach(model.lists.filter { $0.folderId == folder.id }) { list in
              Text(list.name).tag(Optional(list.id))
            }
          } header: {
            Label(folder.name, systemImage: "folder")
              .foregroundStyle(.secondary)
          }
        }
        Section("Ungrouped") {
          ForEach(rootLists) { list in
          Text(list.name).tag(Optional(list.id))
          }
        }
      }
      .listStyle(.sidebar)

      Divider()
      HStack(spacing: 8) {
        AddWorkspaceItemButton(title: "New list", systemImage: "plus") { name in
          model.createList(named: name)
        }
        AddWorkspaceItemButton(title: "New folder", systemImage: "folder.badge.plus") { name in
          model.createFolder(named: name)
        }
      }
      .padding(10)
    }
    .background(.bar)
  }

  @ViewBuilder
  private var taskPane: some View {
    if let list = model.selectedList {
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(list.name).font(.title2.weight(.semibold))
            if let scope = model.scopeTask {
              Button {
                model.leaveTaskScope()
              } label: {
                Label(scope.title, systemImage: "chevron.left")
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            } else {
              Text("Open tasks and projects")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
        .padding(20)

        List {
          ForEach(model.outline) { item in
            taskRow(item)
          }
        }
        .listStyle(.inset)

        TaskComposer { title in model.createTask(named: title) }
          .padding(14)
      }
    } else {
      ContentUnavailableView("No list selected", systemImage: "list.bullet")
    }
  }

  private func taskRow(_ item: TaskOutlineItem) -> some View {
    HStack(spacing: 8) {
      Button {
        model.toggleTask(item.task)
      } label: {
        Image(systemName: item.task.status == .open ? "circle" : "checkmark.circle.fill")
          .foregroundStyle(item.task.status == .open ? Color.secondary : Color.green)
      }
      .buttonStyle(.plain)

      Text(item.task.title)
        .strikethrough(item.task.status != .open)
        .foregroundStyle(item.task.status == .open ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture { model.selectTask(item.task) }
      Spacer(minLength: 8)
      Button {
        model.enterTask(item.task)
      } label: {
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help("Enter subtasks")
    }
    .padding(.leading, CGFloat(item.depth) * 22)
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("INSPECTOR")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
      Divider()
      if let task = model.selectedTask {
        Text(task.title).font(.headline)
        if !task.notes.isEmpty {
          Text(task.notes)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(8)
        }
        if model.activeFocusSession != nil {
          Button {
            model.addToFocusQueue(task)
          } label: {
            Label("Add to focus queue", systemImage: "plus.circle")
          }
          .buttonStyle(.borderedProminent)
          Button("Open focus panel") { model.showsFocusPanel = true }
            .buttonStyle(.link)
        } else {
          Button {
            model.startFocus(on: task)
          } label: {
            Label("Start focus", systemImage: "bolt.fill")
          }
          .buttonStyle(.borderedProminent)
        }
      } else {
        Text("Select a task to see its notes, schedule, estimate, and focus controls here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(18)
    .background(.background)
  }
}

private struct LocalFocusPanel: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let onFloat: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label("FOCUS", systemImage: "bolt.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Hide") { dismiss() }
          .buttonStyle(.plain)
      }

      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        Text(task.title)
          .font(.title2.weight(.semibold))
          .lineLimit(3)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(timeRemaining(session: session, now: context.date))
            .font(.system(size: 42, weight: .bold, design: .monospaced))
            .foregroundStyle(.tint)
        }
        Text("One task at a time. The queue stays editable while you work.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Divider()
        Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        ForEach(model.focusQueue) { queued in
          HStack {
            Image(systemName: queued.item.state == .completed ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(queued.item.state == .completed ? Color.green : Color.secondary)
            Text(queued.task.title)
            Spacer()
          }
        }

        HStack {
          Button("Done") { model.completeFocusedTask() }
            .buttonStyle(.borderedProminent)
          Button("Float timer") { onFloat() }
            .buttonStyle(.bordered)
          Button("End session", role: .destructive) { model.finishFocus() }
            .buttonStyle(.bordered)
        }
      } else {
        ContentUnavailableView("Focus session complete", systemImage: "checkmark.circle")
      }
    }
    .padding(28)
    .frame(width: 440, height: 520, alignment: .topLeading)
  }

  private func timeRemaining(session: FocusSession, now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(session.startedAt))
    let seconds = max(0, session.workDurationSeconds - Int(elapsed))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

private struct TaskComposer: View {
  @State private var title = ""
  let onSubmit: (String) -> Void

  var body: some View {
    HStack {
      Image(systemName: "plus")
        .foregroundStyle(.secondary)
      TextField("Add a task", text: $title)
        .textFieldStyle(.plain)
        .onSubmit { submit() }
    }
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(title)
    title = ""
  }
}

private struct AddWorkspaceItemButton: View {
  let title: String
  let systemImage: String
  let onSubmit: (String) -> Void
  @State private var isPresenting = false
  @State private var name = ""

  var body: some View {
    Button {
      isPresenting = true
    } label: {
      Image(systemName: systemImage)
    }
    .help(title)
    .popover(isPresented: $isPresenting) {
      VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        TextField("Name", text: $name)
          .onSubmit { submit() }
        HStack {
          Spacer()
          Button("Add") { submit() }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding()
      .frame(width: 220)
    }
  }

  private func submit() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    onSubmit(name)
    name = ""
    isPresenting = false
  }
}
