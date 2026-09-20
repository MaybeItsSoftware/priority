import PriorityWorkspace
import SwiftUI

struct WorkspaceDailiesDashboard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var visibleTaskIDs: Set<String> = []

  var body: some View {
    let _ = model.dailyProgressRevision
    let items = model.dailyItems
    let done = items.filter(\.isDoneToday).count
    ScrollViewReader { scrollProxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
              Text("DAILIES")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
              Spacer()
              if !items.isEmpty {
                Text("\(done) of \(items.count) done")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(done == items.count ? Color.green : .secondary)
              }
            }
            Text("Every daily moves one task forward. Ticking one records today’s contribution — the task itself stays open until it is genuinely finished.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if items.isEmpty {
            ContentUnavailableView(
              "No dailies due today",
              systemImage: "arrow.triangle.2.circlepath",
              description: Text("Select a task and enable Make daily progress in the inspector to commit to it daily."))
          } else {
            ForEach(items) { item in
              WorkspaceDailyProgressRow(item: item)
                .environment(model)
                .id(item.task.id)
            }
          }
        }
        .scrollTargetLayout()
        .padding(20)
      }
      .onScrollTargetVisibilityChange(idType: String.self) { ids in
        visibleTaskIDs = Set(ids)
      }
      .onChange(of: model.selectedTaskID) { _, id in
        guard let id, !visibleTaskIDs.contains(id),
          items.contains(where: { $0.task.id == id }) else { return }
        scrollProxy.scrollTo(id, anchor: .center)
      }
    }
  }
}

private struct WorkspaceDailyProgressRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @FocusState private var isRowFocused: Bool
  let item: DailyItem

  private var task: WorkspaceTask { item.task }

  var body: some View {
    HStack {
      Button {
        model.toggleDailyProgress(task)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Label(task.title, systemImage: item.isDoneToday ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(item.isDoneToday ? Color.green : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(task.title)
          HStack(spacing: 6) {
            if let list = model.list(for: task) {
              Text(list.name)
            }
            if item.secondsLoggedToday > 0 {
              Text("· \(item.secondsLoggedToday / 60)m logged today")
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      Spacer()
      Button("Focus") {
        model.selectTask(task)
        if model.activeFocusSession == nil { model.startFocus(on: task) } else if model.activeFocusTask?.id == task.id { model.showsFocusPanel = true } else { model.addToFocusQueue(task) }
      }
      .buttonStyle(.bordered)
      .focusable()
    }
    .padding(10)
    .contentShape(Rectangle())
    .onDrag { WorkspaceTaskDrag.provider(for: task.id) }
    .background(
      task.id == model.selectedTaskID ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 8))
    .focusable()
    .focused($isRowFocused)
    .focusEffectDisabled()
    .onChange(of: isRowFocused) { _, focused in
      if focused { model.selectTask(task) }
    }
    .onChange(of: model.selectedTaskID) { _, id in
      if id == task.id && !isRowFocused { isRowFocused = true }
    }
    .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, "i"]) { press in
      guard isRowFocused else { return .ignored }
      if press.key == .upArrow {
        model.selectAdjacentTask(by: -1)
      } else if press.key == .downArrow {
        model.selectAdjacentTask(by: 1)
      } else if press.key == "i" {
        model.toggleInspector()
      } else {
        model.toggleDailyProgress(task)
      }
      return .handled
    }
  }
}
