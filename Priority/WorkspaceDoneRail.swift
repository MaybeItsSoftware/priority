import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The right-hand rail of finished work.
///
/// Read beside the board rather than instead of it: the question "am I getting
/// anywhere" is answered by setting what you closed today against what is still
/// open, and a screen of its own would put those two facts on separate screens.
/// The day headings are the whole design — a flat list of everything you have
/// ever ticked off is not progress, it is an archive.
struct WorkspaceDoneRail: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The tally that used to sit in a strip of its own here is on the end of
      // the dock's tab bar, so the list starts right under the one rule.
      if model.completedTasks.isEmpty {
        empty
      } else {
        rows
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // The page, like every other pane: the dock is set apart by the hairline
    // beside it, not by a tint of its own.
    .background(theme.paper)
    // No focus bar down the leading edge any more: the cursor row's hairline
    // already says the keyboard is here, and a second, thicker line beside the
    // resize handle boxed the whole rail in.
    .contentShape(Rectangle())
    .onTapGesture { model.reportKeyboardFocus(.done) }
  }

  /// Centred muted text on the empty surface, like every other empty pane.
  private var empty: some View {
    Text("Nothing finished yet. Tasks you tick off appear here, newest first.")
      .font(theme.bodyFont())
      .foregroundStyle(theme.muted)
      .multilineTextAlignment(.center)
      .padding(theme.space.xl)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var rows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(model.doneGroups) { group in
            Section {
              ForEach(group.items) { task in
                WorkspaceDoneRow(task: task)
                  .id(task.id)
              }
            } header: {
              WorkspaceDoneDayHeader(group: group)
            }
          }
        }
        .padding(.bottom, theme.space.md)
      }
      .onChange(of: model.doneCursorID) { _, id in
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
      }
    }
  }
}

/// Today against the week it belongs to — the same pair the day view reads,
/// because two numbers with no denominator say nothing about a day.
struct WorkspaceDoneSummary: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    let progress = model.workProgress
    let today = progress.today.completed
    HStack(spacing: theme.space.xs) {
      Text("\(today) today")
        .foregroundStyle(today > 0 ? theme.success : theme.dim)
      if progress.week.completed > today {
        Text("· \(progress.week.completed) this week")
          .foregroundStyle(theme.dim)
      }
    }
    // The pane counts' face, since it now sits where they do: on the end of a
    // header band.
    .font(theme.monoFont(size: theme.type.microLabel.size))
    .monospacedDigit()
    .help("Tasks finished today, and this week")
  }
}

/// A day's heading, pinned so the day you are scrolled into stays named.
private struct WorkspaceDoneDayHeader: View {
  @Environment(\.theme) private var theme
  let group: CompletedWorkGroup<WorkspaceTask>

  var body: some View {
    HStack(spacing: theme.space.xs) {
      MicroLabel(Self.label(for: group))
      Spacer(minLength: theme.space.xs)
      MicroLabel("\(group.items.count)")
    }
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.xs)
    // Opaque because it is pinned: rows scroll under it.
    .background(theme.paper)
    .overlay(alignment: .bottom) { FocusRule() }
  }

  /// The words are the view's business and the arithmetic is not — see
  /// `CompletedWorkDigest`. A weekday name is enough inside the last week; past
  /// that it stops identifying one day and needs a date.
  static func label(for group: CompletedWorkGroup<WorkspaceTask>) -> String {
    switch group.kind {
    case .today: return "Today"
    case .yesterday: return "Yesterday"
    case .thisWeek: return group.dayStart.formatted(.dateTime.weekday(.wide))
    case .earlier: return group.dayStart.formatted(.dateTime.day().month(.abbreviated))
    }
  }
}

private struct WorkspaceDoneRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask

  private var isCursor: Bool { model.doneCursorTask?.id == task.id }
  private var hasKeyboard: Bool { isCursor && model.keyboardFocusArea == .done }

  /// Cancelled is not completed. Both leave the open list, so both belong here,
  /// but a rail that reads them the same would be telling you that dropping
  /// something and finishing it are the same result.
  private var wasCancelled: Bool { task.status == .cancelled }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      Image(systemName: wasCancelled ? "xmark" : "checkmark")
        .font(theme.bodyFont(size: theme.type.microLabel.size))
        .foregroundStyle(wasCancelled ? theme.dim : theme.success)
        .frame(width: 11)
      VStack(alignment: .leading, spacing: 0) {
        Text(task.title)
          .font(theme.bodyFont())
          .foregroundStyle(wasCancelled ? theme.muted : theme.ink)
          .strikethrough(wasCancelled)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: theme.space.xs) {
          if let name = model.lists.first(where: { $0.id == task.listId })?.name {
            Text(name).lineLimit(1).truncationMode(.middle)
          }
          if let at = task.completedAt {
            Text(at.formatted(date: .omitted, time: .shortened))
              .monospacedDigit()
          }
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.dim)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, theme.space.xs)
    // The gutter is split round the highlight rather than laid inside it, so
    // the selection stops short of the rail's edges the way an outline or
    // sidebar row's does, while the text stays on the day headings' gutter.
    .padding(.horizontal, theme.space.xl - theme.space.sm)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: hasKeyboard)
    .padding(.horizontal, theme.space.sm)
    .onTapGesture {
      model.doneCursorID = task.id
      model.reportKeyboardFocus(.done)
    }
    .commandHelp(.doneReveal, note: task.title)
    .contextMenu {
      Button("Open where it lives") { model.revealDoneTask(task) }
        .commandShortcut(.doneReveal)
      Button("Put back on the list") { model.reopenDoneTask(task) }
        .commandShortcut(.doneReopen)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(task.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.revealDoneTask(task) }
  }
}
