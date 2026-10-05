import XCTest

@testable import TaktCore

final class CompletionMilestonePolicyTests: XCTestCase {

  // MARK: - Tier selection

  func testOrdinaryCompletionIsOrdinary() {
    let milestone = CompletionMilestonePolicy.milestone(
      for: .task(id: 1),
      remainingVisibleTaskCount: 7,
      ordinal: 3
    )
    XCTAssertEqual(milestone, .ordinary)
    XCTAssertFalse(milestone.earnsFlourish)
  }

  /// The count is taken before the optimistic removal, so "the last one" is 1.
  /// Off-by-one here would mean the flourish either never fires or fires one
  /// task early, and neither is visible in a unit-less eyeball test.
  func testLastVisibleTaskClearsTheList() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 1, ordinal: 3),
      .listCleared
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 2, ordinal: 3),
      .ordinary
    )
  }

  /// Defensive: a caller that reads the count after removal passes 0. That
  /// should still read as "the list is now empty", not fall through to ordinary.
  func testZeroRemainingAlsoClearsTheList() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 0, ordinal: 1),
      .listCleared
    )
  }

  func testEveryTenthCompletionEarnsATally() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 10),
      .dailyTally(count: 10)
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 20),
      .dailyTally(count: 20)
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 11),
      .ordinary
    )
  }

  /// The day's first completion is ordinal 1, not 0 — it must not read as a
  /// tally just because 0 is divisible by ten.
  func testFirstCompletionOfTheDayIsNotATally() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 1),
      .ordinary
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 0),
      .ordinary
    )
  }

  /// Clearing the list on your tenth completion is one celebration, not two.
  func testClearingTheListOutranksATally() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 1, ordinal: 10),
      .listCleared
    )
  }

  func testDailyTickIsAlwaysDailyTicked() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .daily(id: "habit"), remainingVisibleTaskCount: 4, ordinal: 3),
      .dailyTicked
    )
    // A daily never reads as "list cleared" — an empty *task* list says nothing
    // about the dailies list it isn't in.
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .daily(id: "habit"), remainingVisibleTaskCount: 1, ordinal: 3),
      .dailyTicked
    )
    // …and it outranks a tally on the same tick.
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .daily(id: "habit"), remainingVisibleTaskCount: 4, ordinal: 10),
      .dailyTicked
    )
  }

  /// The flourish is for occasions that say something the inline celebration
  /// does not. A streak, a tally and an emptied list each carry a fact; a tick
  /// carries none, and `milestone(for:…)` returns `dailyTicked` for every tick
  /// of every daily — several times a morning.
  ///
  /// It mattered more than "one animation too many". Strike draws its flourish
  /// as a rule swept across the panel, the same gesture as the row's own
  /// strikethrough, so every tick put a second strikethrough on screen at a
  /// fixed point unrelated to the row that caused it.
  func testRoutineCompletionsSkipTheFlourish() {
    XCTAssertFalse(CompletionMilestone.ordinary.earnsFlourish)
    XCTAssertFalse(
      CompletionMilestone.dailyTicked.earnsFlourish,
      "a daily tick is the most routine action in the app")
    XCTAssertTrue(CompletionMilestone.listCleared.earnsFlourish)
    XCTAssertTrue(CompletionMilestone.dailyTally(count: 10).earnsFlourish)
    XCTAssertTrue(CompletionMilestone.dailyStreak(days: 4).earnsFlourish)
  }

  /// The day's first tick still earns its streak: `milestone(for:…)` checks the
  /// streak *before* the `isDaily` short-circuit, so quietening the tick does
  /// not quieten the one occasion a tick can legitimately mark.
  func testTheDaysFirstTickStillEarnsItsStreak() {
    let first = CompletionMilestonePolicy.milestone(
      for: .daily(id: "habit"), remainingVisibleTaskCount: 4, ordinal: 1, streakDays: 9)
    XCTAssertEqual(first, .dailyStreak(days: 9))
    XCTAssertTrue(first.earnsFlourish)
  }

  // MARK: - Streaks

  /// Only on the day's opening completion. A streak is a property of the day,
  /// so marking it once is the point — firing it again at noon would say
  /// nothing new and would cost the flourish the rarity it trades on.
  func testStreakFiresOnlyOnTheDaysFirstCompletion() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 1, streakDays: 4),
      .dailyStreak(days: 4)
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 2, streakDays: 4),
      .ordinary
    )
  }

  /// Two days is "yesterday and today", which happens constantly. Celebrating
  /// it would make the rarest-looking effect in the app one of the commonest.
  func testShortRunsDoNotEarnAStreak() {
    for days in 0..<CompletionMilestonePolicy.streakMinimum {
      XCTAssertEqual(
        CompletionMilestonePolicy.milestone(
          for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 1, streakDays: days),
        .ordinary,
        "a \(days)-day run should not be a milestone"
      )
    }
  }

  /// Precedence. Clearing the list is rarer still and absorbs the streak rather
  /// than queueing behind it; the streak in turn outranks a daily tick, which
  /// happens several times most mornings.
  func testStreakSitsBelowClearingTheListAndAboveADailyTick() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 1, ordinal: 1, streakDays: 9),
      .listCleared
    )
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .daily(id: "h"), remainingVisibleTaskCount: 5, ordinal: 1, streakDays: 9),
      .dailyStreak(days: 9)
    )
  }

  /// A caller with no day log passes zero, which must read as "not known"
  /// rather than as a zero-day streak worth mentioning.
  func testUnknownStreakDefaultsToNoMilestone() {
    XCTAssertEqual(
      CompletionMilestonePolicy.milestone(
        for: .task(id: 1), remainingVisibleTaskCount: 5, ordinal: 1),
      .ordinary
    )
  }

  // MARK: - Flourish weight

  /// The ordering is the fix: clearing your entire list used to draw the same
  /// 1.5pt hairline as ticking one daily, which made the rarest event in the
  /// app quieter than the row that caused it.
  func testFlourishWeightRanksTheOccasions() {
    XCTAssertEqual(CompletionMilestone.ordinary.flourishWeight, 0)
    XCTAssertLessThan(
      CompletionMilestone.dailyTicked.flourishWeight,
      CompletionMilestone.dailyTally(count: 10).flourishWeight
    )
    XCTAssertLessThan(
      CompletionMilestone.dailyTally(count: 10).flourishWeight,
      CompletionMilestone.dailyStreak(days: 5).flourishWeight
    )
    XCTAssertLessThan(
      CompletionMilestone.dailyStreak(days: 5).flourishWeight,
      CompletionMilestone.listCleared.flourishWeight
    )
    XCTAssertEqual(CompletionMilestone.listCleared.flourishWeight, 1.0)
  }

  /// Only the occasions carrying a number get words — the other two are legible
  /// as motion, and an empty list announces itself.
  func testOnlyCountedOccasionsCarryACaption() {
    XCTAssertEqual(CompletionMilestone.dailyStreak(days: 5).caption, "5 day streak")
    XCTAssertEqual(CompletionMilestone.dailyTally(count: 20).caption, "20 today")
    XCTAssertNil(CompletionMilestone.listCleared.caption)
    XCTAssertNil(CompletionMilestone.dailyTicked.caption)
    XCTAssertNil(CompletionMilestone.ordinary.caption)
  }

  func testKindReportsWhetherItIsADaily() {
    XCTAssertTrue(CompletionKind.daily(id: "h").isDaily)
    XCTAssertFalse(CompletionKind.task(id: 1).isDaily)
  }

  // MARK: - Durations

  /// Not zero: a zero-length animation leaves SwiftUI no frame to interpolate,
  /// so the row would jump rather than resolve.
  func testReducedMotionCollapsesButDoesNotRemoveDuration() {
    XCTAssertEqual(CompletionMilestonePolicy.durationScale(reduceMotion: false), 1.0)
    let reduced = CompletionMilestonePolicy.durationScale(reduceMotion: true)
    XCTAssertGreaterThan(reduced, 0)
    XCTAssertLessThan(reduced, 1.0)
  }

  /// The budget is the whole point of the seam: a preset that asks for a second
  /// of blocking animation would delay the close request by a second.
  func testRequestedDurationIsClampedToTheBudget() {
    let clamped = CompletionMilestonePolicy.clampedDuration(
      5.0,
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: false
    )
    XCTAssertEqual(clamped, CompletionMilestonePolicy.inlineBudget, accuracy: 0.0001)
  }

  func testShortDurationPassesThroughUnchanged() {
    let clamped = CompletionMilestonePolicy.clampedDuration(
      0.05,
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: false
    )
    XCTAssertEqual(clamped, 0.05, accuracy: 0.0001)
  }

  func testReducedMotionScalesBeforeClamping() {
    let clamped = CompletionMilestonePolicy.clampedDuration(
      0.10,
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: true
    )
    XCTAssertEqual(
      clamped,
      0.10 * CompletionMilestonePolicy.durationScale(reduceMotion: true),
      accuracy: 0.0001
    )
  }

  func testNegativeDurationIsFlooredAtZero() {
    XCTAssertEqual(
      CompletionMilestonePolicy.clampedDuration(
        -1, budget: CompletionMilestonePolicy.inlineBudget, reduceMotion: false),
      0
    )
  }

  /// The shipped sequence is ~210ms of blocking animation. If the budget ever
  /// drifts below that, the default preset silently gets cut short.
  func testInlineBudgetStillCoversTheShippedSequence() {
    XCTAssertGreaterThanOrEqual(CompletionMilestonePolicy.inlineBudget, 0.21)
    XCTAssertGreaterThan(
      CompletionMilestonePolicy.flourishBudget,
      CompletionMilestonePolicy.inlineBudget
    )
  }

  // MARK: - Row treatments

  /// "None" has to be inert on every axis, not just the obvious one — the row
  /// checks `!= .none` to decide whether to colour its edge marker.
  func testNoneTreatmentChangesNothing() {
    let none = CelebrationRowTreatment.none
    XCTAssertFalse(none.drawsStrikethrough)
    XCTAssertEqual(none.tintOpacity, 0)
    XCTAssertEqual(none.scale, 1.0)
    XCTAssertFalse(none.collapses)
    XCTAssertFalse(none.fades)
  }

  /// Guards the shipped look: a line, a wash, a one-percent nudge on the row,
  /// and a pop on the checkmark.
  func testStrikeTreatmentMatchesTheShippedLook() {
    XCTAssertTrue(CelebrationRowTreatment.strike.drawsStrikethrough)
    XCTAssertEqual(CelebrationRowTreatment.strike.tintOpacity, 0.14, accuracy: 0.0001)
    XCTAssertEqual(CelebrationRowTreatment.strike.scale, 1.01, accuracy: 0.0001)
    XCTAssertEqual(CelebrationRowTreatment.strike.iconPop, 1.35, accuracy: 0.0001)
    XCTAssertFalse(CelebrationRowTreatment.strike.collapses)
  }

  /// The retune's whole premise. A row is full-bleed and has no nearby edge to
  /// measure a percent or two against, so the row scale was doing the work
  /// invisibly; the glyph is small and fixated on, so the same emphasis reads
  /// there. If a future preset ever inverts this, it should be deliberate.
  func testTheIconCarriesMoreEmphasisThanTheRow() {
    for treatment in [CelebrationRowTreatment.strike, .spark] {
      XCTAssertGreaterThan(
        treatment.iconPop - 1.0, treatment.scale - 1.0,
        "the glyph is where a completion is felt, not the row")
    }
  }

  /// Fold removes the row; a glyph growing while its container folds shut is
  /// two effects fighting, which is the same reason Fold has no strikethrough.
  func testFoldDoesNotPopTheIcon() {
    XCTAssertEqual(CelebrationRowTreatment.fold.iconPop, 1.0, accuracy: 0.0001)
  }

  func testNoneLeavesTheIconAlone() {
    XCTAssertEqual(CelebrationRowTreatment.none.iconPop, 1.0, accuracy: 0.0001)
  }

  /// The collapse is the statement; a line through a vanishing row is two
  /// effects fighting.
  func testFoldCollapsesAndDoesNotStrikeThrough() {
    XCTAssertTrue(CelebrationRowTreatment.fold.collapses)
    XCTAssertTrue(CelebrationRowTreatment.fold.fades)
    XCTAssertFalse(CelebrationRowTreatment.fold.drawsStrikethrough)
  }

  func testSparkKeepsTheStrikeUnderABrighterWash() {
    XCTAssertTrue(CelebrationRowTreatment.spark.drawsStrikethrough)
    XCTAssertGreaterThan(
      CelebrationRowTreatment.spark.tintOpacity,
      CelebrationRowTreatment.strike.tintOpacity
    )
    XCTAssertFalse(CelebrationRowTreatment.spark.collapses)
  }

  func testEveryTreatmentIsDistinguishableFromNone() {
    for treatment in [
      CelebrationRowTreatment.strike,
      CelebrationRowTreatment.fold,
      CelebrationRowTreatment.spark,
    ] {
      XCTAssertNotEqual(treatment, .none)
    }
  }
}
