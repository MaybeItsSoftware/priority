import AppKit
import PriorityCore
import SwiftUI

enum PopoverLayout {
  static let width: CGFloat = 400
  static let kanbanColumnWidth: CGFloat = 100
  static let minHeight: CGFloat = 220
  static let maxHeight: CGFloat = 520
  /// The Daily view stacks a checklist, a chart and a completions list — three
  /// things worth seeing together — so it gets more room than the single
  /// scrolling list the shared cap was sized for.
  static let dailyMaxHeight: CGFloat = 680
  /// The Matrix view's unplaced drawer, when the dock has it open.
  ///
  /// Fixed rather than content-sized: it is a scrolling list, and a block whose
  /// height tracked its contents would resize the plot above it every time you
  /// placed something — the grid moving under the pointer mid-sort.
  static let matrixUnplacedDrawerHeight: CGFloat = 170

  @MainActor
  static func preferredWidth(for manager: AppCoordinator) -> CGFloat {
    // Keep the popover width constant across views so the root tab bar doesn't
    // shift horizontally when switching to kanban. Kanban columns flex to fill.
    width
  }
  static let cornerRadius: CGFloat = 10
  static let topStripHeight: CGFloat = 6
  static let rootScopeHorizontalInset: CGFloat = 8
  static let rowHorizontalPadding: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 7
  static let rowIconWidth: CGFloat = 16
  static let rowContentSpacing: CGFloat = 10
  static let rowTextFadeWidth: CGFloat = 18
  /// One level of outline indent. Narrow on purpose: the popover is 400pt wide
  /// and a deep subtree still has to leave room for the task itself.
  static let outlineIndentWidth: CGFloat = 14
  static let inlineEntryVerticalPadding: CGFloat = 7
  /// The bottom dock row, present in every view.
  static let dockHeight: CGFloat = 24
  /// The drag strip, shown only when the dock's resize button is on.
  static let resizeStripHeight: CGFloat = 8

  // Onboarding bar heights. `PopoverView` pins the panel to `preferredHeight`
  // and clips to a rounded rect, and the onboarding bar is the last element in
  // the stack — so under-reserving here doesn't scroll or compress anything, it
  // silently amputates the bottom of the bar. Both values are derived from the
  // bars' actual layout and rounded *up*; over-reserving only adds slack.

  /// `pluginSelectionOnboardingBar`: title, wrapped subtitle, four toggle rows,
  /// and the Done/Preferences row, in a `VStack(spacing: 10)` with 10pt of
  /// vertical padding either side.
  static let pluginSelectionOnboardingBarHeight: CGFloat = {
    let title: CGFloat = 15  // .system(size: 12, weight: .semibold)
    let subtitle: CGFloat = 28  // .caption2, wraps to two lines at this width
    let toggleRows: CGFloat = 4 * 16 + 3 * 6  // four .mini switches, 6pt apart
    let buttons: CGFloat = 24  // .controlSize(.small)
    let spacing: CGFloat = 3 * 10
    let padding: CGFloat = 2 * 10
    return title + subtitle + toggleRows + buttons + spacing + padding
  }()

  /// The single-action bars (Checkvist, Obsidian, …): title over a two-line
  /// message, with the action buttons alongside rather than below.
  static let compactOnboardingBarHeight: CGFloat = 72

  /// Everything the popover stacks *around* the current view: the top strip,
  /// the dock, and whichever bars and prompts are showing.
  ///
  /// Split out so a view can work out how much room it is actually being given
  /// — `preferredHeight` minus this — rather than measuring itself and feeding
  /// the answer back into its own layout.
  @MainActor
  static func fixedChromeHeight(for manager: AppCoordinator) -> CGFloat {
    let dividerHeight: CGFloat = 1

    // Top strip + first divider.
    var fixedHeight: CGFloat = topStripHeight + dividerHeight

    // The dock row is in every view, with a divider above it *and* one closing
    // the content area off. Missing that second hairline is small enough to
    // look like nothing and large enough to leave a visible strip of bare panel
    // under a view that sizes itself from what is left.
    fixedHeight += dividerHeight + dockHeight + dividerHeight
    if manager.popoverChrome.isResizeHandleVisible {
      fixedHeight += resizeStripHeight
    }

    if !manager.taskListViewModel.breadcrumbs.isEmpty || manager.navigationState.currentParentId != 0 {
      fixedHeight += 30 + dividerHeight
    }
    if manager.taskListViewModel.shouldShowRootScopeSection {
      // 27pt is measured; the filter-controls variant is still an estimate.
      fixedHeight += (manager.taskListViewModel.rootScopeShowsFilterControls ? 72 : 27) + dividerHeight
    }
    if manager.preferences.showTaskBreadcrumbContext {
      fixedHeight += 24 + dividerHeight
    }
    if manager.taskListViewModel.hideFuture {
      fixedHeight += 24 + dividerHeight
    }
    if manager.quickEntry.pendingDeleteConfirmation {
      fixedHeight += 40
    }
    let showsSearchPrompt =
      !manager.quickEntry.pendingDeleteConfirmation
      && manager.quickEntry.quickEntryMode == .search
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.searchText.isEmpty)
      && (!manager.taskListViewModel.visibleTasks.isEmpty || !manager.quickEntry.searchText.isEmpty)
    let showsQuickAddPrompt =
      !manager.quickEntry.pendingDeleteConfirmation
      && (manager.quickEntry.quickEntryMode == .quickAddDefault
        || manager.quickEntry.quickEntryMode == .quickAddSpecific)
      && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty)
    if showsSearchPrompt || showsQuickAddPrompt {
      fixedHeight += 40
    }
    if !manager.quickEntry.pendingDeleteConfirmation
      && (manager.quickEntry.quickEntryMode == .command
        && (manager.quickEntry.isQuickEntryFocused || !manager.quickEntry.quickEntryText.isEmpty))
    {
      // Input row + autocomplete list block.
      fixedHeight += 220
    }
    if !manager.quickEntry.pendingDeleteConfirmation,
      let activeOnboardingDialog = manager.onboardingService.activeOnboardingDialog
    {
      switch activeOnboardingDialog {
      case .pluginSelection:
        fixedHeight += pluginSelectionOnboardingBarHeight
      default:
        fixedHeight += compactOnboardingBarHeight
      }
    }
    if manager.repository.errorMessage != nil || manager.statusMessage != nil {
      fixedHeight += 20
    }

    return fixedHeight
  }

  /// Everything in the Daily view except the checklist rows.
  @MainActor
  static func dailyReservedHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.reservedHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory,
      showsCompletions: dailyShowsCompletions(for: manager),
      isAddingDaily: manager.dailyLog.isAddingDaily
    )
  }

  /// Whether the Daily view is actually drawing its completed-tasks list: the
  /// dock toggle is on *and* the day has something in it. Both halves have to
  /// agree with `DailyView`, so the condition lives here rather than being
  /// written out at each site.
  @MainActor
  static func dailyShowsCompletions(for manager: AppCoordinator) -> Bool {
    manager.popoverChrome.showsDailyCompletions
      && !manager.dailyLog.summary().completed.isEmpty
  }

  /// The chart and its range row — what a dragged Daily height has added to it
  /// when the graph is on, and taken off it before being stored. The same term
  /// `dailyReservedHeight` uses, so the two can't disagree about what the chart
  /// costs.
  @MainActor
  static func dailyChartBlockHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.chartBlockHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory
    )
  }

  /// Every Daily block the dock can switch on and off. A dragged height is
  /// stored without these, so toggling one grows or shrinks the panel by its
  /// own height rather than eating into the checklist.
  @MainActor
  static func dailyToggleableBlockHeight(for manager: AppCoordinator) -> CGFloat {
    DailyChecklistLayout.toggleableBlockHeight(
      showsChart: manager.popoverChrome.showsDailyChart,
      hasFullChartHistory: manager.dailyLog.hasFullChartHistory,
      showsCompletions: dailyShowsCompletions(for: manager)
    )
  }

  /// What the Matrix view's dock toggle is worth in height. The drawer opens
  /// *under* a square plot rather than out of it, so the panel grows by exactly
  /// this and the grid keeps the size it had.
  @MainActor
  static func matrixToggleableBlockHeight(for manager: AppCoordinator) -> CGFloat {
    manager.popoverChrome.showsMatrixUnplaced ? matrixUnplacedDrawerHeight : 0
  }

  /// Every block the dock can switch on and off in whichever root view is up.
  @MainActor
  static func toggleableBlockHeight(for manager: AppCoordinator) -> CGFloat {
    switch manager.taskListViewModel.rootTaskView {
    case .daily: return dailyToggleableBlockHeight(for: manager)
    case .eisenhower: return matrixToggleableBlockHeight(for: manager)
    default: return 0
    }
  }

  /// Converts a height the user has just dragged the panel to into the value
  /// that gets stored. A view keeps its stored height free of the dock's
  /// optional blocks, so toggling one moves the panel rather than the content.
  @MainActor
  static func storedHeight(forDisplayed height: CGFloat, in manager: AppCoordinator) -> CGFloat {
    height - toggleableBlockHeight(for: manager)
  }

  @MainActor
  static func preferredHeight(for manager: AppCoordinator) -> CGFloat {
    if manager.needsInitialSetup {
      return 430
    }

    // A dragged height wins outright, and is checked before anything else
    // because the kanban branch below returns unconditionally — content-derived
    // sizing is a good default and a bad argument once the user has said what
    // they want.
    if let override = manager.popoverChrome.height(for: manager.taskListViewModel.rootTaskView) {
      // A view's height is stored *without* its toggleable blocks, so switching
      // the graph, the done-today list or the matrix's unplaced drawer on grows
      // the panel by exactly that block's height instead of taking the room out
      // of the content.
      return override + toggleableBlockHeight(for: manager)
    }

    let fixedHeight = fixedChromeHeight(for: manager)

    if manager.taskListViewModel.rootTaskView == .kanban {
      return maxHeight
    }

    if manager.taskListViewModel.rootTaskView == .eisenhower {
      // `+ width` is the plot asking to be square. The drawer is added after
      // the cap rather than inside it, so opening the list lengthens the panel
      // instead of flattening the grid.
      return min(maxHeight, fixedHeight + width) + matrixToggleableBlockHeight(for: manager)
    }

    // Sized to its own content rather than the task count: the dailies
    // checklist, the chart, and the capped completions list. The container has to
    // include the chart's baseline or the card grows a nested scroll bar.
    if manager.taskListViewModel.rootTaskView == .daily {
      // Sized by `DailyChecklistLayout` rather than here: the view divides the
      // same budget up again to decide how many whole rows its checklist can
      // show, and the two answers have to come from one set of numbers.
      let dailyContentHeight = DailyChecklistLayout.contentHeight(
        reserved: dailyReservedHeight(for: manager),
        count: manager.dailyLog.todaysDailies.count
      )
      // Its own ceiling: this view stacks four sections that are each worth
      // seeing at once, where the task views are one scrolling list that the
      // shared cap suits fine.
      return min(dailyMaxHeight, max(minHeight, fixedHeight + dailyContentHeight))
    }

    let taskAreaHeight: CGFloat
    if manager.repository.isLoading && manager.repository.tasks.isEmpty {
      taskAreaHeight = 90
    } else if manager.taskListViewModel.visibleTasks.isEmpty {
      taskAreaHeight = 150
    } else {
      let visibleTasks = manager.taskListViewModel.visibleTasks
      let sectionRows = manager.taskListViewModel.rootDueSectionCount(in: visibleTasks)
      let visibleRows = CGFloat(min(visibleTasks.count + sectionRows, 8))
      // 36pt is measured: a bare task row. One carrying a metadata line runs to
      // 40, so a full list still scrolls — but 34 was under every real row, and
      // the slack that used to hide it went when the chrome count was corrected.
      taskAreaHeight = max(110, visibleRows * 36)
    }

    return min(maxHeight, max(minHeight, fixedHeight + taskAreaHeight))
  }
}
