import Foundation
import Observation
import TaktCore

/// State for the popover's own chrome — the bits of the window that aren't any
/// one view's content.
///
/// Kept apart from the view managers because it is genuinely cross-cutting: the
/// dock row renders in every root view. Hanging it off `DailyLogManager` meant
/// the Daily view owned a preference the All view also needed, which is
/// exactly the coupling `ARCHITECTURE_IMPROVEMENT_PLAN.md` asks new work not
/// to add to.
@MainActor
@Observable final class PopoverChromeManager {
  @ObservationIgnored private let preferencesStore: PreferencesStore

  /// Whether the Daily view draws its chart. Off makes the Daily view a compact
  /// checklist, which is what you want on a day you're just ticking things off.
  var showsDailyChart: Bool {
    didSet { preferencesStore.set(showsDailyChart, for: .dailyChartVisible) }
  }

  /// Whether the Daily view lists the tasks closed today underneath its
  /// checklist. Off by default: the Daily view answers "what do I do every
  /// day", and what you happened to finish in the All list is a different
  /// question that was crowding the answer.
  var showsDailyCompletions: Bool {
    didSet { preferencesStore.set(showsDailyCompletions, for: .dailyCompletionsVisible) }
  }

  /// Whether the keyboard reference sheet is up. Deliberately *not* persisted:
  /// it is something you consult, not a mode you work in, and a popover that
  /// reopened showing its own help would be one you had to dismiss every
  /// morning.
  var showsShortcutReference: Bool = false

  /// Whether the diagnostics sheet is up. Not persisted, for the same reason as
  /// the reference sheet: it is something you open when something is wrong, not
  /// a mode you work in. Only the main window can show it — a sheet needs a
  /// titled window to attach to, and the panel is a non-activating one.
  var showsDiagnostics: Bool = false

  init(preferencesStore: PreferencesStore) {
    self.preferencesStore = preferencesStore
    self.showsDailyChart = preferencesStore.bool(.dailyChartVisible, default: true)
    self.showsDailyCompletions = preferencesStore.bool(
      .dailyCompletionsVisible, default: false)
  }
}
