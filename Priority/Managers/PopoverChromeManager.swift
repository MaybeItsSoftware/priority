import Foundation
import Observation
import PriorityCore

/// State for the popover's own chrome — the bits of the window that aren't any
/// one view's content.
///
/// Kept apart from the view managers because it is genuinely cross-cutting: the
/// dock row renders in every root view, the height override applies to all of
/// them, and `MenuBarController` has to observe the lot to resize the `NSWindow`
/// underneath. Hanging it off `DailyLogManager` (where the first version of the
/// resize handle lived) meant the Daily view owned a preference the All view
/// also needed, which is exactly the coupling `ARCHITECTURE_IMPROVEMENT_PLAN.md`
/// asks new work not to add to.
@MainActor
@Observable final class PopoverChromeManager {
  /// Bounds for a dragged height.
  ///
  /// The floor matters more than it looks: the drag strip lives *inside* the
  /// panel, so a height too short to render it would be unrecoverable without
  /// editing defaults by hand. Clamped on write and again on read at launch, so
  /// a value outside the range can't exist even if the stored data is edited.
  static let minPanelHeight: CGFloat = 240
  static let maxPanelHeight: CGFloat = 900

  @ObservationIgnored private let preferencesStore: PreferencesStore

  /// Per root view, because these views want very different amounts of room —
  /// the Daily view stacks four sections, the All view is one list. One shared
  /// height would be wrong for at least one of them at all times.
  private(set) var panelHeightOverrides: [RootTaskView: CGFloat] = [:]

  /// Whether the drag strip is showing. Persisted: if you resize often enough to
  /// turn it on, having it come back is the point.
  var isResizeHandleVisible: Bool {
    didSet { preferencesStore.set(isResizeHandleVisible, for: .popoverResizeHandleVisible) }
  }

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

  /// Whether the Matrix view opens its unplaced list under the plot. Off makes
  /// the matrix a square grid and nothing else, which is what it is for; on
  /// gives you the thing you drag from, and grows the panel by the list's own
  /// height rather than squaring the plot off.
  var showsMatrixUnplaced: Bool {
    didSet { preferencesStore.set(showsMatrixUnplaced, for: .matrixUnplacedVisible) }
  }

  /// The pile the Matrix drawer is currently listing, if any.
  ///
  /// Held as the point rather than as the members, so tasks arriving in the
  /// pile or being completed out of it do not close what you were reading. A
  /// pile whose goal has moved no longer exists at that point, and the drawer
  /// falls back to the unplaced list.
  ///
  /// Not persisted, for the same reason as the sheets below: it is somewhere
  /// you are looking, not a mode you work in, and a popover that reopened
  /// inside one pile of forty would be hiding the plot for a reason you would
  /// not remember by morning.
  var openMatrixPile: MatrixPileKey?

  /// The quadrant filling the grid, if one is focused.
  ///
  /// Not persisted, like the open pile: it is somewhere you are looking, and a
  /// popover that reopened showing a quarter of its own plot would be one you
  /// had to zoom out of every morning.
  var focusedMatrixQuadrant: MatrixQuadrant?

  /// Whether the Matrix view draws its drawer at all.
  ///
  /// An open pile shows the drawer without touching the toggle, so closing the
  /// pile leaves the drawer exactly as you had it rather than switched on.
  var showsMatrixDrawer: Bool { showsMatrixUnplaced || openMatrixPile != nil }

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
    self.isResizeHandleVisible = preferencesStore.bool(
      .popoverResizeHandleVisible, default: false)
    self.showsDailyChart = preferencesStore.bool(.dailyChartVisible, default: true)
    self.showsDailyCompletions = preferencesStore.bool(
      .dailyCompletionsVisible, default: false)
    self.showsMatrixUnplaced = preferencesStore.bool(.matrixUnplacedVisible, default: false)

    let stored = preferencesStore.doubleDictionary(.panelHeightOverridesByRootView)
    var overrides: [RootTaskView: CGFloat] = [:]
    for (rawKey, value) in stored {
      guard let raw = Int(rawKey), let view = RootTaskView(rawValue: raw), value > 0 else {
        continue
      }
      overrides[view] = Self.clamped(CGFloat(value))
    }
    self.panelHeightOverrides = overrides
  }

  // MARK: - Height

  func height(for view: RootTaskView) -> CGFloat? {
    panelHeightOverrides[view]
  }

  func setHeight(_ height: CGFloat, for view: RootTaskView) {
    panelHeightOverrides[view] = Self.clamped(height)
    persistHeights()
  }

  /// Back to sizing from content. Bound to a double-click on the strip, so there
  /// is always a way out of a height that turned out to be wrong.
  func resetHeight(for view: RootTaskView) {
    guard panelHeightOverrides.removeValue(forKey: view) != nil else { return }
    persistHeights()
  }

  private static func clamped(_ height: CGFloat) -> CGFloat {
    min(maxPanelHeight, max(minPanelHeight, height))
  }

  private func persistHeights() {
    let encoded = Dictionary(
      uniqueKeysWithValues: panelHeightOverrides.map { (String($0.key.rawValue), Double($0.value)) }
    )
    preferencesStore.set(encoded, for: .panelHeightOverridesByRootView)
  }
}
