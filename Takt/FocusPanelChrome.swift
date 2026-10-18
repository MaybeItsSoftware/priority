import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// A key the panel's field hands to the place it is in, rather than typing.
enum FocusPanelFieldKey: Equatable {
  case up, down, left, escape, commandDelete, enter, commandEnter, space, tab
}

/// The panel's one field: what you type searches or filters the place it is
/// in, and Return adds it. Every place mounts the same one, so it looks and
/// answers the same on Today, on a list and in the list switcher; what each
/// key means there is the place's (`onKey`).
struct FocusPanelField: View {
  @Environment(\.theme) private var theme
  let prompt: String
  @Binding var query: String
  var isFocused: FocusState<Bool>.Binding
  var help: String?
  let onKey: (FocusPanelFieldKey) -> KeyPress.Result

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: "magnifyingglass")
        .font(theme.bodyFont())
        .foregroundStyle(theme.dim)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .focused(isFocused)
        .onKeyPress(.upArrow) { onKey(.up) }
        .onKeyPress(.downArrow) { onKey(.down) }
        .onKeyPress(.leftArrow) { onKey(.left) }
        .onKeyPress(.escape) { onKey(.escape) }
        // ⌘⌫ is the field's own "delete to the start of the line" while
        // there is text in it; the place decides what it means without.
        .onKeyPress(keys: [.delete], phases: .down) { press in
          press.modifiers.contains(.command) ? onKey(.commandDelete) : .ignored
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
          onKey(press.modifiers.contains(.command) ? .commandEnter : .enter)
        }
        .onKeyPress(.space) { onKey(.space) }
        .onKeyPress(.tab) { onKey(.tab) }
        .help(help ?? prompt)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
    // An input is a hairline on the page, not a well sunk into it.
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(isFocused.wrappedValue ? theme.focusRing : theme.inputBorder, lineWidth: theme.hairline))
    .padding(.horizontal, theme.space.lg)
    .padding(.bottom, theme.space.md)
  }
}

/// The panel's header controls beside the place's name: the list switcher,
/// the main window, and hiding the panel.
struct FocusPanelHeaderButtons: View {
  let onChooseList: () -> Void
  let onOpenWindow: () -> Void
  let onClose: () -> Void

  var body: some View {
    WorkspacePaneIconButton("list.bullet", title: "Go to a list", note: "Go to a list (⌘P)", action: onChooseList)
    WorkspacePaneIconButton("macwindow", title: "Open the main window", note: "Open the main window (⌘↩)",
      action: onOpenWindow)
    WorkspacePaneIconButton("xmark", title: "Hide the focus panel", note: "Hide the panel (esc)", action: onClose)
  }
}

/// The running block as one line over a list: its task, its clock, pause and
/// Done. Today draws the block as its own card; a list is somewhere else, so
/// the block comes with you as a line, and a double-click goes back to it.
struct FocusPanelRunningLine: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let onShowDay: () -> Void

  var body: some View {
    if let session = model.activeFocusSession, let task = model.activeFocusTask {
      HStack(spacing: theme.space.sm) {
        Text(task.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let text = session.phase == .onBreak
            ? "break \(FocusTimerDisplay.breakReading(endsAt: session.breakEndsAt, now: context.date).text)"
            : FocusTimerDisplay.reading(
              elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
              planned: TimeInterval(session.workDurationSeconds)).text
          Text(session.pausedAt != nil ? "\u{23F8} \(text)" : text)
            .font(theme.numeralFont(theme.scale.body, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(session.pausedAt == nil ? theme.primary : theme.muted)
            .lineLimit(1)
            .fixedSize()
        }
        Button {
          if session.phase == .onBreak { model.endFocusBreak() } else { model.toggleFocusPause() }
        } label: {
          Image(systemName: session.pausedAt == nil && session.phase != .onBreak ? "pause.fill" : "play.fill")
        }
        .buttonStyle(FocusActionButtonStyle())
        .focusable(false)
        .help(session.phase == .onBreak ? "Back to work" : session.pausedAt == nil ? "Pause" : "Resume")
        Button { model.requestFocusCompletion(from: .panel) } label: {
          Label("Done", systemImage: "checkmark")
        }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .focusable(false)
        .help("Done · ⇧⌘↩")
      }
      .padding(.horizontal, theme.space.lg)
      .padding(.vertical, theme.space.sm)
      .background(theme.primary.opacity(Theme.statusFillOpacity))
      .overlay(alignment: .leading) {
        Rectangle().fill(theme.primary).frame(width: theme.emphasisBorder)
      }
      .overlay(alignment: .bottom) { FocusRule() }
      .contentShape(Rectangle())
      .onTapGesture(count: 2, perform: onShowDay)
      .help("The running block. Double-click for Today, where it is a card with all its controls")
    }
  }
}

/// ⌘P in the panel: Today and every list and nested list, filtered as you
/// type, in quick add's rows. Return goes there; Esc goes back to where the
/// panel was.
struct FocusPanelListSwitcher: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let summons: FocusPanelSummons
  let onClose: (FocusPanelDismissal) -> Void

  @State private var query = ""
  @State private var selectedID: String?
  @FocusState private var isFieldFocused: Bool

  /// The id Today's row answers to; a list's id is a UUID.
  private static let todayID = "takt:today"

  private var showsToday: Bool {
    let needle = query.trimmingCharacters(in: .whitespaces)
    return needle.isEmpty || WorkspaceCommandQuery.fuzzyScore(needle, in: "Today") != nil
  }

  /// In sidebar order with nothing typed; otherwise ranked as the list
  /// finder ranks, the name counting for more than where it lives.
  private var destinations: [QuickCaptureDestination] {
    let all = model.quickCaptureDestinations
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return all }
    let scored: [(QuickCaptureDestination, Int)] = all.compactMap { destination in
      let title = WorkspaceCommandQuery.fuzzyScore(needle, in: destination.title).map { $0 * 2 }
      let path = WorkspaceCommandQuery.fuzzyScore(needle, in: destination.path)
      guard let best = [title, path].compactMap({ $0 }).max() else { return nil }
      return (destination, best)
    }
    return scored.enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .map(\.element.0)
  }

  private var rowIDs: [String] { (showsToday ? [Self.todayID] : []) + destinations.map(\.id) }

  private var currentID: String { summons.listID ?? Self.todayID }

  var body: some View {
    let ids = rowIDs
    VStack(spacing: 0) {
      WorkspacePaneHeader(title: "Go to") {
        EmptyView()
      } trailing: {
        WorkspacePaneIconButton("xmark", title: "Back", note: "Back (esc)") { summons.isChoosingList = false }
      }
      FocusPanelField(
        prompt: "Today, or a list…", query: $query, isFocused: $isFieldFocused, onKey: fieldKey)
      FocusRule()
      WorkspaceDestinationRows(
        destinations: destinations, selectedID: selectedID,
        note: { $0.id == currentID ? "Current" : nil },
        header: { if showsToday { todayRow } },
        onPick: { open($0.id) })
      .frame(maxHeight: .infinity)
      WorkspaceOverlayFooter(hints: "↑↓ choose · ↩ go · ⌘T today · esc back", trailing: "\(ids.count)")
    }
    .background(WindowKeyMonitor(handle: chord))
    .onAppear {
      selectDefault()
      DispatchQueue.main.async { isFieldFocused = true }
    }
    .onChange(of: query) { _, _ in selectDefault() }
  }

  private var todayRow: some View {
    HStack(spacing: theme.space.sm) {
      Label("Today", systemImage: "sun.max")
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Spacer(minLength: theme.space.sm)
      if currentID == Self.todayID {
        Text("Current").font(theme.captionFont).foregroundStyle(theme.dim)
      }
    }
    .font(theme.bodyFont())
    .overlayRow(isSelected: selectedID == Self.todayID)
    .id(Self.todayID)
    .onTapGesture { open(Self.todayID) }
  }

  /// The first row that is somewhere else, so ⌘P ↩ goes somewhere.
  private func selectDefault() {
    let ids = rowIDs
    selectedID = ids.first { $0 != currentID } ?? ids.first
  }

  private func fieldKey(_ key: FocusPanelFieldKey) -> KeyPress.Result {
    let ids = rowIDs
    switch key {
    case .up, .down:
      guard !ids.isEmpty else { return .handled }
      let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
      selectedID = ids[CursorStepping.index(from: current, by: key == .up ? -1 : 1, count: ids.count)]
      return .handled
    case .enter, .tab:
      if let selectedID { open(selectedID) }
      return .handled
    case .escape:
      if !query.isEmpty { query = "" } else { summons.isChoosingList = false }
      return .handled
    case .commandEnter:
      onClose(.toWindow)
      AppDelegate.shared.showMainWindow()
      return .handled
    case .left, .commandDelete, .space:
      return .ignored
    }
  }

  /// ⌘T and ⌘{ / ⌘} go straight there; ⌘P again goes back.
  private func chord(_ event: NSEvent) -> Bool {
    guard model.panelOverlay == nil, let key = event.workspaceCommandKey,
      let action = FocusPanelKeys.action(forKey: key, on: .outline),
      FocusPanelKeys.reachesFromField(action, key: key)
    else { return false }
    switch action {
    case .chooseList: summons.isChoosingList = false
    case .goToday, .place: summons.go(action, model: model)
    default: return false
    }
    return true
  }

  private func open(_ id: String) {
    summons.show(listID: id == Self.todayID ? nil : id)
  }
}
