import TaktCore
import TaktWorkspace
import SwiftUI

/// What a day row's shell needs to know, worked out once by the list.
///
/// The list used to build every row inline, so an arrow key — which changes
/// one row's selection and the next one's — re-ran every row's body, and every
/// row resolved its task through the model (subscribing the list to every
/// refresh) to ask whether it was being celebrated. The answers are plain
/// values now, and a row whose values did not move is not redrawn.
struct DayRowChrome: Equatable {
  let id: String
  let isPanel: Bool
  let isSelected: Bool
  /// The cursor row while the window's keyboard is on the tasks.
  let hasKeyboard: Bool
  let isHovered: Bool
  let isActive: Bool
  /// How the row is celebrated when it is finished; nil for the create row.
  let completion: CompletionKind?
}

/// One row shape for every row, so a row that gains controls is visibly the
/// same row rather than a different kind of thing.
///
/// Flat on the page with a hairline under it. What a row *is* reads from a
/// tint of the matching hue: the running one in primary, the one under the
/// cursor in the selection fill, the one being finished in success — never a
/// raised card or a stock accent.
struct DayRowCard<Content: View>: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  let chrome: DayRowChrome
  let content: Content
  let onHover: (Bool) -> Void
  let onTap: () -> Void

  init(
    chrome: DayRowChrome, onHover: @escaping (Bool) -> Void, onTap: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.chrome = chrome
    self.onHover = onHover
    self.onTap = onTap
    self.content = content()
  }

  /// The side padding inside a row. In the window, the pane's gutter, so a
  /// task's title starts under the header's "Today" the way the outline's
  /// start under its list name; the panel keeps its own narrower figure,
  /// being a small floating surface rather than a pane.
  private var rowGutter: CGFloat { chrome.isPanel ? theme.space.lg : theme.paneGutter }

  /// Above and below a row's content. The window uses the rows' shared
  /// figure, so a two-line day row is as dense as two outline rows.
  private var rowPadding: CGFloat { chrome.isPanel ? theme.space.sm : theme.rowVerticalPadding }

  var body: some View {
    // The card being finished takes whatever the active celebration preset
    // does to a row, so the tick, the tint and the collapse are the same
    // gesture here as on the focus ladder. Read here rather than by the list,
    // so a celebration playing redraws its own row and no other.
    let phase = chrome.completion.map { manager.celebration.phase(for: $0) } ?? .idle
    let treatment = manager.celebration.rowTreatment
    let celebrating = phase != .idle
    let fill: Color =
      celebrating ? theme.success.opacity(treatment.tintOpacity)
      : chrome.isSelected ? theme.selectionFill
      : chrome.isActive ? theme.primary.opacity(Theme.statusFillOpacity)
      : chrome.isHovered ? theme.hover : Color.clear
    content
      .padding(.horizontal, rowGutter)
      .padding(.vertical, rowPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .scaleEffect(treatment.rowScale(for: phase))
      .background(fill)
      // The running row keeps a primary edge even under the cursor, so the
      // selection never hides which task is the one on the clock.
      .overlay(alignment: .leading) {
        if chrome.isActive || celebrating {
          Rectangle()
            .fill(celebrating ? theme.success : theme.primary)
            .frame(width: theme.emphasisBorder)
        }
      }
      .overlay(alignment: .bottom) { FocusRule() }
      .overlay {
        // In the window the cursor row carries the same hairline in the focus
        // colour as every other pane's while the keyboard is on the tasks.
        // The panel has one region, so its fill says it all.
        if chrome.hasKeyboard {
          Rectangle().strokeBorder(theme.focusRing, lineWidth: theme.hairline)
        }
      }
      .overlay {
        if celebrating, let completion = chrome.completion {
          manager.celebration.rowAccent(for: completion)
            .allowsHitTesting(false)
        }
      }
      .opacity(treatment.fades && phase == .celebrating ? 0 : 1)
      .contentShape(Rectangle())
      .onHover(perform: onHover)
      .onTapGesture(perform: onTap)
  }
}

/// What an ordinary row says, worked out by the list from what it already
/// read, so the row itself reads nothing from the model to draw.
struct DayTaskFacts: Equatable {
  let task: WorkspaceTask
  /// Its position in the day; nil for a search result.
  let index: Int?
  let isActive: Bool
  let completion: CompletionKind
  let isDaily: Bool
  let isDailyDone: Bool
  /// "12m / 25m", "12m" or "25m"; nil when the task has neither.
  let cost: String?
}

/// An ordinary row: what it is, what it should cost, what it has cost.
///
/// Equatable on its values and not its closures: the closures only ever call
/// back into the list, and a row whose values are the same draws the same.
struct DayTaskRow: View, Equatable {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let facts: DayTaskFacts
  let listName: String?
  let detail: String?
  let chrome: DayRowChrome
  let onHover: (Bool) -> Void
  let onTap: () -> Void
  let onTick: () -> Void

  nonisolated static func == (lhs: DayTaskRow, rhs: DayTaskRow) -> Bool {
    lhs.facts == rhs.facts && lhs.listName == rhs.listName && lhs.detail == rhs.detail
      && lhs.chrome == rhs.chrome
  }

  private var task: WorkspaceTask { facts.task }

  var body: some View {
    // The row under the cursor grows to show all of its text; the rest stay
    // one line each. Baseline-aligned while it is grown, so the number, the
    // list and the time stay on the first line beside the title's start.
    let isExpanded = chrome.isSelected
    let alignment: VerticalAlignment = isExpanded ? .firstTextBaseline : .center
    DayRowCard(chrome: chrome, onHover: onHover, onTap: onTap) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        HStack(alignment: alignment, spacing: theme.space.sm) {
          marker
          Text(task.title)
            .font(theme.bodyFont())
            .foregroundStyle(theme.ink)
            .expandsWhenSelected(isExpanded)
          if facts.isDaily {
            DailyBadge(task: task, isDoneToday: facts.isDailyDone)
          }
          Spacer(minLength: theme.space.sm)
          if let listName {
            MicroLabel(listName).lineLimit(1).fixedSize(horizontal: isExpanded, vertical: false)
          }
          // Time only once there is some: logged against the estimate, or
          // either alone. A column of "No estimate" and 00:00 down a fresh
          // day was the noisiest thing on the screen and said nothing.
          if let cost = facts.cost {
            DayEstimateLabel(
              text: cost,
              help: "Set the time estimate (\(WorkspaceCommandHelpText.firstKey(for: .taskEditEstimate)))",
              action: chrome.isPanel ? nil : {
                model.selectedTaskID = task.id
                model.quickEdit(.estimate)
              })
          }
        }
        if let detail {
          Text(detail)
            .font(theme.captionFont)
            .foregroundStyle(theme.dim)
            .expandsWhenSelected(isExpanded)
            .padding(.leading, WorkspaceRowMetrics.indent(theme))
        }
      }
    }
  }

  /// A row's number, which becomes the way to tick it off when the pointer is
  /// over it.
  ///
  /// Blitzit's list has a checkbox on every row and this one had nothing: the
  /// day list could start work but not finish it, so anything already done had
  /// to be closed somewhere else. The number and the tick share one slot
  /// because the row is narrow and they are never both wanted at once.
  private var marker: some View {
    Button(action: onTick) {
      Group {
        if chrome.isHovered {
          Image(systemName: "checkmark.circle")
            .font(theme.bodyFont())
            .foregroundStyle(theme.success)
        } else if let index = facts.index {
          Text("\(index)")
            .font(theme.numeralFont(theme.scale.caption))
            .monospacedDigit()
            .foregroundStyle(theme.dim)
        } else {
          // No empty box down the column; the tick shows under the pointer.
          Image(systemName: "circle")
            .font(theme.captionFont)
            .hidden()
        }
      }
      .frame(width: WorkspaceRowMetrics.iconWidth, alignment: .trailing)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help("Tick off without running a block (Space)")
    .accessibilityLabel("Tick off \(task.title)")
  }
}
