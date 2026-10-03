import AppKit
import Observation
import PriorityCore
import SwiftUI
import os

/// Owns which completion celebration is active, runs it, and holds the
/// post-mutation flourish for the popover overlay to render.
///
/// Modelled on `DailyLogManager`: a thin `@Observable` that keeps the plugin
/// reference, write-throughs the user's choice, and bumps state SwiftUI can
/// watch. Unlike the other plugin capabilities, the registry is retained rather
/// than read once at launch, because the user can switch presets at runtime.
///
/// It is also the `CelebrationStage` presets talk to, and — since the completing
/// flag moved here off `QuickEntryManager` — the single owner of "which row is
/// mid-completion, and how far through". Every surface reads
/// `phase(for:)`; nothing reaches around it.
@MainActor
@Observable final class CompletionCelebrationManager: CelebrationStage {
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let registry: PluginRegistry
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "CompletionCelebrationManager")

  /// Fallback when nothing is stored, or when a stored identifier no longer
  /// resolves (a preset removed between releases).
  static let defaultCelebrationIdentifier = "native.celebration.strike"

  /// How far past `inlineBudget` a preset may run before the manager stops
  /// waiting on it.
  ///
  /// Not zero, because the budget is a target for the *script* and a frame of
  /// scheduling slop either side of it is normal. Small, because the whole
  /// point is that no preset — including a third-party one written against this
  /// protocol — can make completing a task feel slow.
  private static let budgetGrace: TimeInterval = 0.06

  /// The row currently mid-completion, and how far through it is.
  ///
  /// One pair rather than the two flags this replaces (`completingTaskId` on
  /// `QuickEntryManager` for tasks, `completingDailyId` here for dailies). The
  /// split meant every surface had to know which storage its rows lived in, and
  /// the kanban card — which read `completingTaskId` directly — was the one
  /// that drifted out of step.
  private(set) var completingKind: CompletionKind?
  private(set) var phase: CelebrationPhase = .idle

  /// The flourish currently on screen, if any. The identity is carried
  /// separately so two consecutive milestones re-trigger `onAppear` instead of
  /// SwiftUI reusing the first one's view.
  private(set) var activeFlourish: (id: UUID, view: AnyView)?

  /// The preset's blocking half, retained so it can be called off.
  ///
  /// This is what makes the cancellation contract real. `runInline` has always
  /// documented that it returns `false` when "the user navigated away or
  /// switched tasks mid-animation", and all three presets carried a `catch` for
  /// it — but the mark-done work was spawned as an unretained `Task {}` in the
  /// shortcut router and nothing in the app ever cancelled it, so `Task.sleep`
  /// never threw, the catch branches never ran, and the guard in
  /// `markCurrentTaskDone` could not fire. Holding the handle here, and
  /// cancelling it from `NavigationState.onNavigationChanged`, is what turns
  /// ~30 lines of unreachable error handling into the behaviour they describe.
  @ObservationIgnored private var inlineTask: Task<Bool, Never>?

  /// Set when the watchdog gave up on an overrunning preset, so the outcome can
  /// be told apart from a genuine user cancellation. An overrun must *not*
  /// abandon the user's completion — a slow animation is the preset's problem,
  /// not the task's.
  @ObservationIgnored private var inlineOverran = false

  /// Which run of `runInline` is current. Stands in for reference identity on
  /// `inlineTask`, which `Task`'s being a struct rules out.
  @ObservationIgnored private var inlineRunId = 0

  /// Retained so a tick that is still ringing isn't collected mid-play.
  @ObservationIgnored private var activeSound: NSSound?

  var availableCelebrations: [any CompletionCelebrationPlugin] {
    registry.celebrationPlugins
  }

  /// Mirrors the registry's active identifier as `@Observable` state.
  ///
  /// The registry itself is `@ObservationIgnored` — it is a plain lookup table,
  /// and every other capability resolves out of it exactly once at launch. This
  /// one is switchable from Settings, so the picker needs something to observe;
  /// reading through to the registry would leave the menu showing the old
  /// selection until some unrelated change redrew the pane.
  var activeCelebrationIdentifier: String {
    didSet {
      guard activeCelebrationIdentifier != oldValue else { return }
      guard registry.activateCelebrationPlugin(identifier: activeCelebrationIdentifier) else {
        activeCelebrationIdentifier = oldValue
        return
      }
      preferencesStore.set(activeCelebrationIdentifier, for: .completionCelebrationIdentifier)
    }
  }

  /// Whether the preset's tick is audible. Off by default — see
  /// `CelebrationSound` for why it exists at all.
  var soundEnabled: Bool {
    didSet {
      guard soundEnabled != oldValue else { return }
      preferencesStore.set(soundEnabled, for: .completionSoundEnabled)
    }
  }

  /// Resolved through the observed identifier rather than the registry's own
  /// active pointer, so that everything derived from it — `rowTreatment`, the
  /// picker's description line — re-reads when the user switches preset.
  var activeCelebration: any CompletionCelebrationPlugin {
    registry.celebrationPluginsByIdentifier[activeCelebrationIdentifier]
      ?? StrikeCelebrationPlugin()
  }

  /// Read live rather than cached: the user can flip Reduce Motion in System
  /// Settings while the app is running, and a celebration is short enough that
  /// checking per completion costs nothing.
  var prefersReducedMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  init(
    preferencesStore: PreferencesStore,
    registry: PluginRegistry
  ) {
    self.preferencesStore = preferencesStore
    self.registry = registry
    self.soundEnabled = preferencesStore.bool(.completionSoundEnabled, default: false)

    // `activateCelebrationPlugin` returns false for an unknown identifier,
    // which is exactly the "stored preset no longer exists" fallback — the
    // registry keeps whatever `nativeFirst()` activated, and we mirror that
    // rather than the dangling stored value.
    let stored = preferencesStore.string(.completionCelebrationIdentifier)
    if !stored.isEmpty {
      registry.activateCelebrationPlugin(identifier: stored)
    }
    self.activeCelebrationIdentifier =
      registry.activeCelebrationPlugin?.pluginIdentifier
      ?? Self.defaultCelebrationIdentifier
  }

  /// How a row should render while it is completing, per the active preset.
  var rowTreatment: CelebrationRowTreatment {
    activeCelebration.rowTreatment
  }

  /// How far through its completion `kind` is — `.idle` for every row that
  /// isn't the one being completed.
  ///
  /// The single read every surface uses, which is what keeps a new surface from
  /// having to know where the flag lives or which half of the treatment it is
  /// expected to apply.
  func phase(for kind: CompletionKind) -> CelebrationPhase {
    completingKind == kind ? phase : .idle
  }

  /// Extra decoration for the completing row, if the active preset wants any.
  func rowAccent(for kind: CompletionKind) -> AnyView? {
    activeCelebration.makeRowAccent(for: kind)
  }

  // MARK: - CelebrationStage

  func setPhase(_ phase: CelebrationPhase, for kind: CompletionKind?) {
    guard let kind, phase != .idle else {
      self.completingKind = nil
      self.phase = .idle
      return
    }
    self.completingKind = kind
    self.phase = phase
  }

  // MARK: - Running a celebration

  /// Abandons whatever celebration is in flight.
  ///
  /// Wired to `NavigationState.onNavigationChanged`: moving to another row,
  /// zooming into a subtree, or closing the popover all mean the user is no
  /// longer looking at the row they just completed, and a close request that
  /// lands after that is worse than one that never goes out — the row it
  /// removes is not the row they are watching.
  func cancelInFlight() {
    guard let inlineTask else { return }
    self.inlineTask = nil
    inlineTask.cancel()
  }

  /// The blocking half. Returns `false` when the sequence was cancelled, which
  /// the caller must treat as "abandon the mutation".
  ///
  /// Runs the preset inside a task this manager holds, for two reasons that
  /// pull in opposite directions and both matter: the handle is what
  /// `cancelInFlight` cancels, and the watchdog beside it is what stops a
  /// preset that ignores its budget from holding the user's completion open.
  /// An overrun deliberately resolves as success — a preset writing a slow
  /// animation should cost the app its animation, not the user their task.
  func runInline(_ event: CompletionEvent) async -> Bool {
    // A second completion supersedes an unfinished one rather than interleaving
    // with it; two presets driving one phase flag would fight over the row.
    cancelInFlight()
    inlineOverran = false
    playSound(for: event)

    // `Task` is a value type, so the watchdog can't check identity by reference.
    // A run counter does the same job: it tells a woken watchdog whether the run
    // it was started for is still the current one.
    inlineRunId += 1
    let runId = inlineRunId

    let plugin = activeCelebration
    let work = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await plugin.runInline(event, stage: self)
    }
    inlineTask = work

    let watchdog = Task { @MainActor [weak self] in
      let grace = CompletionMilestonePolicy.inlineBudget + Self.budgetGrace
      try? await Task.sleep(for: .seconds(grace))
      guard !Task.isCancelled, let self, self.inlineRunId == runId, self.inlineTask != nil
      else { return }
      self.logger.warning(
        "Celebration '\(plugin.pluginIdentifier, privacy: .public)' overran the inline budget; proceeding without it."
      )
      self.inlineOverran = true
      work.cancel()
    }
    defer { watchdog.cancel() }

    let finished = await work.value
    if inlineRunId == runId { inlineTask = nil }

    if inlineOverran {
      // The preset's own cancel path has already cleared the row, but clear it
      // again unconditionally: an overrunning preset is by definition one whose
      // bookkeeping is not to be trusted.
      setPhase(.idle, for: nil)
      return true
    }
    return finished
  }

  /// The non-blocking half. Call *after* the mutation has been dispatched;
  /// clears itself once the flourish budget is up.
  func presentFlourish(for event: CompletionEvent) {
    guard event.milestone.earnsFlourish,
      let view = activeCelebration.makeFlourish(event)
    else { return }

    let id = UUID()
    activeFlourish = (id, view)
    Task { @MainActor [weak self] in
      guard let self else { return }
      // A beat past the budget, so the flourish isn't torn out of the hierarchy
      // on the exact frame its own animation is still settling on. Scaled with
      // the animation it is waiting for, or reduced motion would leave an
      // invisible view mounted for four times as long as it played.
      let played = CompletionMilestonePolicy.flourishDuration(
        reduceMotion: self.prefersReducedMotion)
      try? await Task.sleep(for: .seconds(played + 0.1))
      // Only clear our own flourish — a newer one may have replaced it while
      // this was sleeping.
      guard self.activeFlourish?.id == id else { return }
      self.activeFlourish = nil
    }
  }

  /// Plays the preset's tick, if it has one and the user asked for sound.
  ///
  /// Fire-and-forget and never awaited: sound is confirmation running alongside
  /// the animation, not a step in it, and a preset must not be able to spend
  /// its inline budget on audio.
  private func playSound(for event: CompletionEvent) {
    guard soundEnabled, let spec = activeCelebration.celebrationSound(for: event) else { return }
    guard let sound = NSSound(named: NSSound.Name(spec.systemName)) else {
      logger.debug("No system sound named '\(spec.systemName, privacy: .public)'.")
      return
    }
    sound.volume = spec.volume
    activeSound = sound
    sound.play()
  }
}
