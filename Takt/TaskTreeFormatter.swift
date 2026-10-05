import Foundation

/// Shared utility for formatting `CheckvistTask` hierarchies as text.
///
/// Two output styles are supported:
///
/// **Tree** (used by clipboard copy) — uses box-drawing characters to visualise
/// the parent→child hierarchy:
/// ```
/// Buy groceries
/// ├── Fruits
/// │   ├── Apples
/// │   └── Bananas
/// └── Dairy
///     └── Milk
/// ```
///
/// **Markdown** (used by task list export) — indented checklist:
/// ```
/// - [ ] Buy groceries
///   - [ ] Fruits
///     - [ ] Apples
/// ```
enum TaskTreeFormatter {

  // MARK: - Tree format (clipboard)

  /// Formats a single root task and all its descendants using tree-drawing
  /// characters (├──, └──, │).
  ///
  /// - Parameters:
  ///   - root: The top-level task whose subtree should be formatted.
  ///   - allTasks: Every task in the list (used to resolve children).
  /// - Returns: A multi-line string. The first line is the root task's content
  ///   (plain text, no prefix); subsequent lines use tree branch characters.
  static func formatAsTree(
    root: CheckvistTask,
    allTasks: [CheckvistTask]
  ) -> String {
    let childrenMap = buildChildrenMap(allTasks)
    var lines: [String] = [root.content]
    appendTreeChildren(
      of: root.id,
      childrenMap: childrenMap,
      prefix: "",
      lines: &lines
    )
    return lines.joined(separator: "\n")
  }

  // MARK: - Markdown format (export)

  /// Formats every task in `tasks` as an indented Markdown checklist.
  ///
  /// Root tasks (those whose `parentId` is `nil`, `0`, or refers to a task not
  /// in the list) appear at the top level; children are indented two spaces per
  /// depth level.
  static func formatAsMarkdown(_ tasks: [CheckvistTask]) -> String {
    let childrenMap = buildChildrenMap(tasks)
    let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    let rootTasks = tasks.filter { task in
      let parentId = task.parentId ?? 0
      return parentId == 0 || taskMap[parentId] == nil
    }.sorted {
      ($0.position ?? Int.max) < ($1.position ?? Int.max)
    }

    var lines: [String] = []

    func appendMarkdownNode(task: CheckvistTask, level: Int) {
      let indent = String(repeating: "  ", count: level)
      let box = task.status == 1 ? "[x]" : "[ ]"
      lines.append("\(indent)- \(box) \(task.content)")
      if let children = childrenMap[task.id] {
        for child in children {
          appendMarkdownNode(task: child, level: level + 1)
        }
      }
    }

    for root in rootTasks {
      appendMarkdownNode(task: root, level: 0)
    }

    return lines.joined(separator: "\n")
  }

  // MARK: - Internal helpers

  /// Builds a lookup from parent ID → sorted child tasks.
  private static func buildChildrenMap(
    _ tasks: [CheckvistTask]
  ) -> [Int: [CheckvistTask]] {
    var map: [Int: [CheckvistTask]] = [:]
    for task in tasks {
      let parentId = task.parentId ?? 0
      map[parentId, default: []].append(task)
    }
    // Sort each group by position so the output order is stable.
    for (parentId, children) in map {
      map[parentId] = children.sorted {
        ($0.position ?? Int.max) < ($1.position ?? Int.max)
      }
    }
    return map
  }

  /// Recursively appends tree-formatted lines for every child of `parentId`.
  ///
  /// - Parameters:
  ///   - parentId: The task whose children should be rendered.
  ///   - childrenMap: Pre-built parent→children lookup.
  ///   - prefix: The inherited prefix from ancestor levels (a combination of
  ///     `"│   "` and `"    "` segments).
  ///   - lines: The output buffer to append to.
  private static func appendTreeChildren(
    of parentId: Int,
    childrenMap: [Int: [CheckvistTask]],
    prefix: String,
    lines: inout [String]
  ) {
    guard let children = childrenMap[parentId] else { return }
    for (index, child) in children.enumerated() {
      let isLast = index == children.count - 1
      let connector = isLast ? "└── " : "├── "
      let statusMark = child.status == 1 ? "✓ " : ""
      lines.append("\(prefix)\(connector)\(statusMark)\(child.content)")
      let childPrefix = prefix + (isLast ? "    " : "│   ")
      appendTreeChildren(
        of: child.id,
        childrenMap: childrenMap,
        prefix: childPrefix,
        lines: &lines
      )
    }
  }
}
