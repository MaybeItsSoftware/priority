#if DEBUG
import Foundation
import TaktWorkspace

@MainActor
extension WorkspaceModel {
  /// Fills a new list with `count` tasks — 250 parents of 19 children, with
  /// a few due dates and estimates — to check the outline stays smooth.
  /// DEBUG only.
  func seedTasks(count: Int = 5_000) {
    let store = store
    let workspaceID = workspace.id
    showToast("Seeding \(count.formatted()) tasks…")
    Task.detached(priority: .userInitiated) {
      let started = Date()
      guard let list = try? store.createList(workspaceId: workspaceID, name: "Seed \(count.formatted())") else { return }
      var made = 0
      var parentIndex = 0
      while made < count {
        parentIndex += 1
        guard let parent = try? store.createTask(listId: list.id, title: "Project \(parentIndex)") else { break }
        made += 1
        for child in 1...19 where made < count {
          let due = child % 7 == 0 ? Calendar.current.date(byAdding: .day, value: child % 3 - 1, to: .now) : nil
          _ = try? store.createTask(
            listId: list.id, title: "Task \(parentIndex).\(child) — something to do", parentTaskId: parent.id,
            dueAt: due, estimateSeconds: child % 4 == 0 ? 1_500 : nil)
          made += 1
        }
      }
      let elapsed = Date().timeIntervalSince(started)
      await MainActor.run { [weak self] in
        self?.didChange()
        self?.showToast("Seeded \(made.formatted()) tasks in \(Int(elapsed))s")
      }
    }
  }
}
#endif

#if DEBUG
import TaktCore

@MainActor
extension WorkspaceModel {
  /// A small, believable workspace for screenshots and poking around.
  func seedDemo() {
    perform { store in
      let workspaceID = workspace.id
      let today = Calendar.current.startOfDay(for: .now)
      func day(_ offset: Int, hour: Int? = nil) -> Date {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
        return hour.map { Calendar.current.date(byAdding: .hour, value: $0, to: date)! } ?? date
      }
      let folder = try store.createFolder(workspaceId: workspaceID, name: "Personal")
      let work = try store.createList(workspaceId: workspaceID, name: "Work")
      let home = try store.createList(workspaceId: workspaceID, name: "Home", folderId: folder.id)
      let reading = try store.createList(workspaceId: workspaceID, name: "Reading", folderId: folder.id)
      try store.updateList(id: work.id, name: "Work", colorHex: "#007fff")
      try store.updateList(id: home.id, name: "Home", colorHex: "#4cc38e")

      let launch = try store.createTask(listId: work.id, title: "Ship the iOS app", estimateSeconds: 7_200, priority: 1)
      let design = try store.createTask(listId: work.id, title: "Polish the outline rows", parentTaskId: launch.id, dueAt: day(0), estimateSeconds: 2_700)
      _ = try store.createTask(listId: work.id, title: "Hairline separators", parentTaskId: design.id)
      _ = try store.createTask(listId: work.id, title: "Fold chevrons", parentTaskId: design.id)
      let readme = try store.createTask(listId: work.id, title: "Write the README", parentTaskId: launch.id, estimateSeconds: 1_800)
      let screenshots = try store.createTask(listId: work.id, title: "Take screenshots", parentTaskId: launch.id, dueAt: day(1))
      let sync = try store.createTask(listId: work.id, title: "Review sync protocol", dueAt: day(-1), estimateSeconds: 3_600, tags: ["sync"])
      let reply = try store.createTask(listId: work.id, title: "Reply to Sam about the roadmap", estimateSeconds: 900)
      let widget = try store.createTask(listId: work.id, title: "Fix the widget refresh", estimateSeconds: 2_700, tags: ["bug"])
      let post = try store.createTask(listId: work.id, title: "Draft the launch post", dueAt: day(3), estimateSeconds: 3_600)
      _ = try store.createTask(listId: work.id, title: "Outline the key points", parentTaskId: post.id)
      _ = try store.createTask(listId: work.id, title: "Pick three screenshots", parentTaskId: post.id)
      let appReview = try store.createTask(listId: work.id, title: "Hear back from App Review")
      let legal = try store.createTask(listId: work.id, title: "Sign-off on the privacy policy", dueAt: day(4))
      let pricing = try store.createTask(listId: work.id, title: "Price the Pro tier", estimateSeconds: 1_800)
      let themes = try store.createTask(listId: work.id, title: "Explore a dark theme for the widgets")
      let quarterly = try store.createTask(listId: work.id, title: "Quarterly planning", kind: .list)
      _ = try store.createTask(listId: work.id, title: "Draft goals", parentTaskId: quarterly.id)

      _ = try store.createTask(listId: home.id, title: "Book the boiler service", dueAt: day(2, hour: 10))
      let groceries = try store.createTask(listId: home.id, title: "Groceries", estimateSeconds: 2_400)
      _ = try store.createTask(listId: home.id, title: "Oat milk", parentTaskId: groceries.id)
      _ = try store.createTask(listId: home.id, title: "Coffee beans", parentTaskId: groceries.id)
      _ = try store.createTask(listId: home.id, title: "Water the plants", startAt: day(0))
      let book = try store.createTask(listId: reading.id, title: "Read ‘The Timeless Way of Building’", estimateSeconds: 3_600)
      var planned = [screenshots.id, groceries.id, readme.id, reply.id]
      if let inbox = try store.inbox(in: workspaceID) {
        planned.append(try store.createTask(listId: inbox.id, title: "Call the dentist", estimateSeconds: 600).id)
        _ = try store.createTask(listId: inbox.id, title: "Idea: weekly review template")
      }
      try store.setPlannedForToday(true, taskIds: planned)
      try store.makeDaily(taskId: design.id, targetSeconds: 1_800)
      try store.makeDaily(taskId: book.id, targetSeconds: 1_200)
      try store.setMatrixPosition(TaskMatrixPosition(urgency: 1, importance: 1), for: launch.id)
      // Spread the Work board over its columns.
      try store.setKanbanColumn("in-progress", for: [launch.id, widget.id])
      try store.setKanbanColumn("this-week", for: [sync.id, post.id])
      try store.setKanbanColumn("waiting-on", for: [appReview.id, legal.id])
      try store.setKanbanColumn("backlog", for: [pricing.id, themes.id])
    }
  }
}
#endif
