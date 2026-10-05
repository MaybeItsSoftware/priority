import XCTest

@testable import TaktCore

/// The timing of a celebration, now that it is data rather than a hand-written
/// sequence of sleeps inside a SwiftUI file.
///
/// None of this was reachable from a test before. `Native/Celebration/` is
/// excluded from the `TaktPlugins` target because celebrations are motion
/// and motion is SwiftUI, so every preset's budget arithmetic lived somewhere
/// nothing could check — which is how the budget came to be enforced per sleep
/// instead of over the sequence, and stayed that way.
final class CelebrationScriptTests: XCTestCase {

  private let budget = CompletionMilestonePolicy.inlineBudget

  // MARK: - Fitting to the budget

  func testAScriptInsideTheBudgetIsUnchanged() {
    let script = CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: 0.02),
        .init(phase: .celebrating, duration: 0.12),
        .init(phase: .celebrating, duration: 0.04),
      ],
      budget: budget,
      reduceMotion: false
    )
    XCTAssertEqual(script.total, 0.18, accuracy: 0.0001)
    XCTAssertEqual(script.steps.count, 3)
  }

  /// The bug this type exists to make impossible. `clampedDuration` bounds one
  /// duration at a time, so three steps each asking for the full budget passed
  /// every clamp individually and still ran for three times the budget.
  func testAnOverrunningScriptIsFittedToTheBudgetInTotal() {
    let greedy = (0..<3).map {
      CelebrationScript.Step(phase: $0 == 0 ? .anticipating : .celebrating, duration: budget)
    }
    // What the old per-step clamp would have allowed.
    let clampedIndividually = greedy.reduce(0) {
      $0
        + CompletionMilestonePolicy.clampedDuration(
          $1.duration, budget: budget, reduceMotion: false)
    }
    XCTAssertEqual(clampedIndividually, budget * 3, accuracy: 0.0001)

    let script = CelebrationScript.fitting(greedy, budget: budget, reduceMotion: false)
    XCTAssertEqual(script.total, budget, accuracy: 0.0001)
  }

  /// Shrinking proportionally rather than truncating: a sequence given half the
  /// room it asked for should keep its shape, not lose its last beat.
  func testFittingPreservesTheProportionsBetweenSteps() {
    let script = CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: 0.1),
        .init(phase: .celebrating, duration: 0.6),
        .init(phase: .celebrating, duration: 0.3),
      ],
      budget: 0.2,
      reduceMotion: false
    )
    XCTAssertEqual(script.total, 0.2, accuracy: 0.0001)
    XCTAssertEqual(script.steps[0].duration, 0.02, accuracy: 0.0001)
    XCTAssertEqual(script.steps[1].duration, 0.12, accuracy: 0.0001)
    XCTAssertEqual(script.steps[2].duration, 0.06, accuracy: 0.0001)
    // And no step is dropped, which truncation would have done to the third.
    XCTAssertEqual(script.steps.count, 3)
  }

  func testPhasesSurviveFitting() {
    let script = CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: 1),
        .init(phase: .celebrating, duration: 1),
      ],
      budget: 0.1,
      reduceMotion: false
    )
    XCTAssertEqual(script.steps.map(\.phase), [.anticipating, .celebrating])
  }

  // MARK: - Reduced motion

  func testReducedMotionScalesTheWholeScript() {
    let requested: [CelebrationScript.Step] = [
      .init(phase: .anticipating, duration: 0.02),
      .init(phase: .celebrating, duration: 0.1),
    ]
    let normal = CelebrationScript.fitting(requested, budget: budget, reduceMotion: false)
    let reduced = CelebrationScript.fitting(requested, budget: budget, reduceMotion: true)
    XCTAssertEqual(
      reduced.total,
      normal.total * CompletionMilestonePolicy.durationScale(reduceMotion: true),
      accuracy: 0.0001
    )
  }

  /// Collapsed, not removed — the same rule the rest of the app follows. A
  /// zero-length script would leave SwiftUI no frame to interpolate and the row
  /// would teleport between states.
  func testReducedMotionDoesNotRemoveTheScript() {
    let reduced = CelebrationScript.fitting(
      [.init(phase: .celebrating, duration: 0.1)],
      budget: budget,
      reduceMotion: true
    )
    XCTAssertGreaterThan(reduced.total, 0)
    XCTAssertLessThan(reduced.total, 0.1)
  }

  // MARK: - Edges

  func testAnEmptyScriptTotalsZero() {
    XCTAssertEqual(CelebrationScript.empty.total, 0)
    XCTAssertTrue(CelebrationScript.empty.steps.isEmpty)
  }

  func testFittingAnEmptyRequestIsEmpty() {
    XCTAssertTrue(CelebrationScript.fitting([], budget: budget, reduceMotion: false).steps.isEmpty)
  }

  /// A preset asking for a negative duration is a preset with a bug; it must
  /// not turn into a negative sleep or drag the fitted total below zero.
  func testNegativeDurationsAreFlooredRatherThanSubtracted() {
    let script = CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: -5),
        .init(phase: .celebrating, duration: 0.1),
      ],
      budget: budget,
      reduceMotion: false
    )
    XCTAssertEqual(script.steps[0].duration, 0, accuracy: 0.0001)
    XCTAssertEqual(script.total, 0.1, accuracy: 0.0001)
  }

  /// A script whose every step is zero must not divide by its own total while
  /// trying to shrink itself.
  func testAnAllZeroScriptDoesNotDivideByZero() {
    let script = CelebrationScript.fitting(
      [.init(phase: .celebrating, duration: 0)],
      budget: budget,
      reduceMotion: false
    )
    XCTAssertEqual(script.total, 0)
  }

  // MARK: - Per-phase treatment

  /// Anticipation is motion only. A tint that arrives before the row has moved
  /// gives the wind-up away, and a strike drawn during it would be drawn twice.
  func testAnticipationAppliesNoTint() {
    let strike = CelebrationRowTreatment.strike
    XCTAssertEqual(strike.tintOpacity(for: .anticipating), 0)
    XCTAssertEqual(strike.tintOpacity(for: .idle), 0)
    XCTAssertEqual(strike.tintOpacity(for: .celebrating), strike.tintOpacity, accuracy: 0.0001)
  }

  /// The wind-up has to go the *other way*, or it is just a slower pop.
  func testAnticipationMovesAwayFromThePeak() {
    for treatment in [CelebrationRowTreatment.strike, .fold, .spark] {
      XCTAssertLessThan(
        treatment.rowScale(for: .anticipating), 1.0,
        "the row must dip below its resting size before it pops")
      XCTAssertLessThan(
        treatment.iconScale(for: .anticipating), 1.0,
        "the glyph must squash before it pops")
    }
  }

  /// `.none` is inert in every phase, including the new one.
  func testNoneIsInertInEveryPhase() {
    for phase in CelebrationPhase.allCases {
      XCTAssertEqual(CelebrationRowTreatment.none.rowScale(for: phase), 1.0, accuracy: 0.0001)
      XCTAssertEqual(CelebrationRowTreatment.none.iconScale(for: phase), 1.0, accuracy: 0.0001)
      XCTAssertEqual(CelebrationRowTreatment.none.tintOpacity(for: phase), 0, accuracy: 0.0001)
      XCTAssertFalse(CelebrationRowTreatment.none.collapses(at: phase))
      XCTAssertFalse(CelebrationRowTreatment.none.fades(at: phase))
      XCTAssertFalse(
        CelebrationRowTreatment.none.marksLeadingEdge(at: phase),
        "a preset that changes nothing must not colour the edge marker either")
    }
  }

  func testIdleIsTheRowsOrdinaryAppearance() {
    for treatment in [CelebrationRowTreatment.strike, .fold, .spark] {
      XCTAssertEqual(treatment.rowScale(for: .idle), 1.0, accuracy: 0.0001)
      XCTAssertEqual(treatment.iconScale(for: .idle), 1.0, accuracy: 0.0001)
      XCTAssertFalse(treatment.collapses(at: .idle))
      XCTAssertFalse(treatment.fades(at: .idle))
      XCTAssertFalse(treatment.marksLeadingEdge(at: .idle))
    }
  }

  /// Fold folds at the peak and nowhere else — collapsing during the wind-up
  /// would remove the row before it had acknowledged the keypress.
  func testFoldOnlyCollapsesAtThePeak() {
    XCTAssertTrue(CelebrationRowTreatment.fold.collapses(at: .celebrating))
    XCTAssertFalse(CelebrationRowTreatment.fold.collapses(at: .anticipating))
    XCTAssertFalse(CelebrationRowTreatment.fold.fades(at: .anticipating))
  }

  // MARK: - Flourish durations

  /// The gap this closes: the inline half went through the reduced-motion scale
  /// from the day it shipped and the flourish half read its budget raw, so the
  /// loudest motion in the app was the one piece of it that ignored the
  /// accessibility setting.
  func testFlourishDurationHonoursReducedMotion() {
    XCTAssertEqual(
      CompletionMilestonePolicy.flourishDuration(reduceMotion: false),
      CompletionMilestonePolicy.flourishBudget,
      accuracy: 0.0001
    )
    XCTAssertLessThan(
      CompletionMilestonePolicy.flourishDuration(reduceMotion: true),
      CompletionMilestonePolicy.flourishBudget
    )
    XCTAssertGreaterThan(CompletionMilestonePolicy.flourishDuration(reduceMotion: true), 0)
  }
}
