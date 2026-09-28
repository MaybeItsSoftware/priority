import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The one place anything is drawn over the workspace: top-anchored, instant,
/// untitled, on the raised surface with a hairline round it.
///
/// It replaced twelve sheets. A sheet slid down from the title bar, took the
/// window's key monitor down with it, and could not be replaced by another —
/// so a command palette that could not be reached from search was the normal
/// state of affairs. Here, whatever `activeOverlay` names is what is up, and
/// clicking anywhere outside it puts it away.
///
/// That click is caught by the window's mouse monitor, not by a SwiftUI layer
/// here. A transparent tap-catcher behind the card never saw clicks over the
/// sidebar or the outline: those are AppKit tables inside the hosting view,
/// and AppKit hands a mouse-down to the deepest `NSView` under it before
/// SwiftUI's gestures get a look. So the card reports its frame, and
/// `MainWindowController` compares each mouse-down against it.
struct WorkspaceOverlayHost: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // No scrim: the overlay is a tool held over the work, not a modal that
    // asks you to stop looking at it.
    ZStack(alignment: .top) {
      if let overlay = model.activeOverlay {
        panel(for: overlay)
          .frame(width: WorkspaceOverlayMetrics.width)
          .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.overlayPanelFrame = frame
          }
          .padding(.top, theme.space.xl)
          .id(overlay.id)
          .transition(.opacity)
      }
    }
    .animation(
      reduceMotion ? nil : .easeOut(duration: WorkspaceOverlayMetrics.fade),
      value: model.activeOverlay?.id)
  }

  @ViewBuilder
  private func panel(for overlay: WorkspaceOverlay) -> some View {
    switch overlay {
    case .commandPalette:
      WorkspaceCommandPalette(overlayID: overlay.id)
    case .search:
      WorkspaceSearchOverlay(overlayID: overlay.id)
    case .listNavigator:
      WorkspaceListNavigator(overlayID: overlay.id)
    case .keyboardReference:
      WorkspaceKeyboardReference(overlayID: overlay.id)
    case .move(let request):
      WorkspaceMoveOverlay(overlayID: overlay.id, request: request)
    case .quickEdit(let request):
      WorkspaceTaskQuickEditOverlay(overlayID: overlay.id, request: request)
    case .create(let kind):
      WorkspaceNameOverlay(
        overlayID: overlay.id, title: kind.title, prompt: "Name",
        context: creationContext(kind)
      ) { name in
        switch kind {
        case .list:
          if model.creationIsNested {
            model.createNestedList(named: name)
          } else {
            model.createList(named: name, in: model.creationParentFolderID)
          }
        case .folder: model.createFolder(named: name, in: model.creationParentFolderID)
        }
      }
    case .newBoardColumn:
      WorkspaceNameOverlay(
        overlayID: overlay.id, title: "New board column", prompt: "Column name", context: nil
      ) { model.addKanbanColumn(named: $0) }
    }
  }

  /// Where the new list or folder will land, which the sheet never said.
  private func creationContext(_ kind: WorkspaceCreationKind) -> String? {
    if kind == .list, model.creationIsNested {
      return model.creationTaskParentID.flatMap { model.task(withID: $0)?.title }
        .map { "In \($0)" } ?? "Nested"
    }
    return model.creationParentFolderID
      .flatMap { id in model.folders.first { $0.id == id }?.name }
      .map { "In \($0)" }
  }
}

/// The overlay's figures, named once. Layout constants rather than theme
/// tokens: the theme owns spacing, radius and type, not how wide a finder is.
enum WorkspaceOverlayMetrics {
  static let width: CGFloat = 600
  /// The height of a result list. Fixed so the panel does not jump as the
  /// matches narrow under the caret.
  static let listHeight: CGFloat = 340
  /// At most a frame or five. Reduce Motion takes it to nothing.
  static let fade: Double = 0.08
}

extension View {
  /// Claims the keys an overlay consumes. The host asks the model, the model
  /// asks this; see `WorkspaceViewModel.handleOverlayKey(_:)`.
  func overlayKeys(
    _ model: WorkspaceViewModel,
    id: String,
    handle: @escaping (String) -> Bool
  ) -> some View {
    onAppear {
      model.overlayKeyHandler = WorkspaceOverlayKeyHandler(overlayID: id, handle: handle)
    }
    .onDisappear {
      if model.overlayKeyHandler?.overlayID == id { model.overlayKeyHandler = nil }
    }
  }
}

// MARK: - Shared chrome

/// The row every overlay opens with: a glyph, a field that has the caret the
/// moment the overlay appears, and a micro-label saying what it is acting on.
struct WorkspaceOverlayField: View {
  @Environment(\.theme) private var theme
  let symbol: String
  let prompt: String
  @Binding var text: String
  var context: String?
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: symbol)
        .foregroundStyle(theme.muted)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .focused($isFocused)
      if let context {
        MicroLabel(context)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
    // A frame late: on the pass that inserts the field it has no window to
    // become first responder in.
    .onAppear { DispatchQueue.main.async { isFocused = true } }
  }
}

/// The strip along the foot of an overlay: which keys do what, and a count.
struct WorkspaceOverlayFooter: View {
  @Environment(\.theme) private var theme
  let hints: String
  var trailing: String?

  var body: some View {
    VStack(spacing: 0) {
      FocusRule()
      HStack(spacing: theme.space.md) {
        Text(hints)
        Spacer(minLength: theme.space.sm)
        if let trailing { Text(trailing) }
      }
      .font(theme.monoFont(size: theme.type.microLabel.size))
      .foregroundStyle(theme.dim)
      .padding(.horizontal, theme.space.md)
      .padding(.vertical, theme.space.xs)
    }
  }
}

/// A quiet line in place of results.
struct WorkspaceOverlayHint: View {
  @Environment(\.theme) private var theme
  let text: String

  var body: some View {
    Text(text)
      .font(theme.bodyFont())
      .foregroundStyle(theme.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// One result row's selection, flat to the panel's edges so the list reads as
/// a list rather than a stack of chips.
extension View {
  func overlayRow(isSelected: Bool) -> some View {
    modifier(WorkspaceOverlayRowStyle(isSelected: isSelected))
  }
}

private struct WorkspaceOverlayRowStyle: ViewModifier {
  @Environment(\.theme) private var theme
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, theme.space.md)
      .padding(.vertical, theme.space.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .workspaceSelection(isSelected: isSelected, hasKeyboard: isSelected, radius: 0)
  }
}

// MARK: - Naming something new

/// A new list, folder or board column: one field, Return makes it.
struct WorkspaceNameOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  let overlayID: String
  let title: String
  let prompt: String
  let context: String?
  let onSubmit: (String) -> Void
  @State private var name = ""

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceOverlayField(symbol: "plus", prompt: "\(title) — \(prompt.lowercased())", text: $name, context: context)
      WorkspaceOverlayFooter(hints: "↩ create · esc cancel")
    }
    .overlayKeys(model, id: overlayID) { key in
      guard key == "enter" else { return false }
      submit()
      return true
    }
  }

  private func submit() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    model.dismissOverlay(restoringFocus: false)
    onSubmit(trimmed)
  }
}

// MARK: - The list finder

/// Every list and nested list, filtered as you type. The workspace's "go to
/// file": ⌘P, then a few letters, then Return.
struct WorkspaceListNavigator: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  @State private var query = ""
  @State private var selection: Int?

  private struct Destination: Identifiable {
    let id: String
    let title: String
    let task: WorkspaceTask?
  }

  private var destinations: [Destination] {
    let lists = model.lists.map { Destination(id: $0.id, title: $0.name, task: nil) }
    let nested = model.nestedLists.map { Destination(id: $0.task.id, title: $0.task.title, task: $0.task) }
    return (lists + nested).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    let items = destinations
    VStack(spacing: 0) {
      WorkspaceOverlayField(symbol: "list.bullet", prompt: "Go to a list", text: $query)
      FocusRule()
      if items.isEmpty {
        WorkspaceOverlayHint(text: "No list matches. ⌘↩ makes one.")
          .frame(height: WorkspaceOverlayMetrics.listHeight)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(items.enumerated()), id: \.element.id) { index, destination in
                Label(destination.title, systemImage: destination.task == nil ? "list.bullet" : "list.bullet.indent")
                  .font(theme.bodyFont())
                  .foregroundStyle(theme.ink)
                  .lineLimit(1)
                  .overlayRow(isSelected: index == (selection ?? 0))
                  .id(index)
                  .onTapGesture { open(destination) }
              }
            }
          }
          .frame(height: WorkspaceOverlayMetrics.listHeight)
          .onChange(of: selection) { _, index in if let index { proxy.scrollTo(index) } }
        }
      }
      WorkspaceOverlayFooter(hints: "↑↓ choose · ↩ open · ⌘↩ new list · esc close", trailing: "\(items.count)")
    }
    .onChange(of: query) { _, _ in selection = nil }
    .overlayKeys(model, id: overlayID) { key in
      let items = destinations
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: items.count)
        return true
      }
      switch key {
      case "enter":
        let index = selection ?? 0
        if items.indices.contains(index) { open(items[index]) }
        return true
      case "cmd+enter":
        model.dismissOverlay(restoringFocus: false)
        model.requestListCreationForSelection()
        return true
      default:
        return false
      }
    }
  }

  private func open(_ destination: Destination) {
    model.dismissOverlay(restoringFocus: false)
    if let task = destination.task { model.selectNestedList(task) } else { model.selectList(destination.id) }
    model.requestKeyboardFocus(.tasks)
  }
}

// MARK: - Moving something

/// Where to move a task or list: every list, nested list and folder it could
/// go to, filtered as you type. It was a pop-up menu in a sheet, which is a
/// mouse control you had to Tab to.
struct WorkspaceMoveOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceItemMoveRequest
  @State private var query = ""
  @State private var selection: Int?
  /// Read once when the overlay opens. It needs the outline beneath the task
  /// being moved, which is a store read, and a body is no place for one.
  @State private var all: [Destination] = []

  struct Destination: Identifiable {
    let id: String
    let name: String
    let listID: String
    let parentTaskID: String?
    var folderID: String?
  }

  private var destinations: [Destination] {
    all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    let items = destinations
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "arrow.right.doc.on.clipboard", prompt: "Move to…", text: $query,
        context: request.title)
      FocusRule()
      if items.isEmpty {
        WorkspaceOverlayHint(text: "Nowhere matches.")
          .frame(height: WorkspaceOverlayMetrics.listHeight)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(items.enumerated()), id: \.element.id) { index, destination in
                Label(destination.name, systemImage: destination.folderID == nil ? "list.bullet" : "folder")
                  .font(theme.bodyFont())
                  .foregroundStyle(theme.ink)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .overlayRow(isSelected: index == (selection ?? 0))
                  .id(index)
                  .onTapGesture { move(to: destination) }
              }
            }
          }
          .frame(height: WorkspaceOverlayMetrics.listHeight)
          .onChange(of: selection) { _, index in if let index { proxy.scrollTo(index) } }
        }
      }
      WorkspaceOverlayFooter(hints: "↑↓ choose · ↩ move · esc cancel", trailing: "\(items.count)")
    }
    .onAppear { all = Self.destinations(for: request, in: model) }
    .onChange(of: query) { _, _ in selection = nil }
    .overlayKeys(model, id: overlayID) { key in
      let items = destinations
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: items.count)
        return true
      }
      guard key == "enter" else { return false }
      let index = selection ?? 0
      if items.indices.contains(index) { move(to: items[index]) }
      return true
    }
  }

  private func move(to destination: Destination) {
    model.dismissOverlay()
    if let folderID = destination.folderID {
      model.moveDroppedItem(request.payload, toFolderID: folderID)
    } else {
      model.moveDroppedItem(request.payload, toListID: destination.listID, parentTaskID: destination.parentTaskID)
    }
  }

  static func destinations(for request: WorkspaceItemMoveRequest, in model: WorkspaceViewModel) -> [Destination] {
    var blocked = Set<String>()
    if let taskID = request.taskID {
      blocked.insert(taskID)
      for item in (try? model.store?.outline(in: request.sourceListID, parentTaskId: taskID)) ?? [] {
        blocked.insert(item.id)
      }
    }
    let roots = model.lists.filter { request.taskID != nil || $0.id != request.sourceListID }
    let listDestinations = roots.flatMap { list in
      [Destination(id: "root:\(list.id)", name: list.name, listID: list.id, parentTaskID: nil)]
        + model.nestedLists.filter { $0.task.listId == list.id && !blocked.contains($0.id) }.map { item in
          Destination(id: item.id, name: "\(list.name) › \(item.task.title)", listID: list.id, parentTaskID: item.id)
        }
    }
    return listDestinations + model.folders.map { folder in
      Destination(id: "folder:\(folder.id)", name: "Folder: \(folder.name)", listID: "", parentTaskID: nil, folderID: folder.id)
    }
  }
}

// MARK: - The keyboard reference

/// The full keyboard reference, read off the same catalogue the keys are.
///
/// It used to be seventy rows typed out by hand next to a switch statement
/// that did the actual work, so the two could disagree and did. Nothing here
/// is written twice: a row exists because a command exists, and prints the
/// key that command is bound to. ⌘K reaches the same list and can run what it
/// lands on; this stays for "show me everything", and filters as you type.
struct WorkspaceKeyboardReference: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  @State private var query = ""

  private var groups: [(name: String, commands: [WorkspaceCommand])] {
    var order: [String] = []
    var byGroup: [String: [WorkspaceCommand]] = [:]
    let needle = query.trimmingCharacters(in: .whitespaces)
    for command in WorkspaceCommandCatalog.all
    where needle.isEmpty || command.title.localizedCaseInsensitiveContains(needle)
      || command.group.localizedCaseInsensitiveContains(needle) {
      if byGroup[command.group] == nil { order.append(command.group) }
      byGroup[command.group, default: []].append(command)
    }
    return order.map { ($0, byGroup[$0] ?? []) }
  }

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceOverlayField(symbol: "keyboard", prompt: "Filter the keyboard reference", text: $query)
      FocusRule()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: theme.space.md) {
          ForEach(groups, id: \.name) { group in
            VStack(alignment: .leading, spacing: theme.space.xs) {
              MicroLabel(group.name)
              ForEach(group.commands) { command in
                row(command)
              }
            }
          }
        }
        .padding(theme.space.md)
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)
      WorkspaceOverlayFooter(hints: "⌘K runs any of these · ↩ or esc close")
    }
    .overlayKeys(model, id: overlayID) { key in
      guard key == "enter" else { return false }
      model.dismissOverlay()
      return true
    }
  }

  private func row(_ command: WorkspaceCommand) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.md) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(command.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
        if let note = command.note {
          Text(note).font(theme.captionFont).foregroundStyle(theme.dim)
        }
      }
      Spacer(minLength: theme.space.md)
      if command.surface != .anywhere {
        MicroLabel(command.surface.title)
      }
      KeyCapRow(keys: command.displayKeys)
    }
  }
}
