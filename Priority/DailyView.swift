import AppKit
import PriorityCore
import SwiftUI

/// The Daily root view: what today looks like, and what the recent run of days
/// looks like behind it.
///
/// Deliberately reads from the daily log rather than from the live task list.
/// Checkvist knows what is open right now; only the log knows what happened,
/// and "what happened" is the entire question this view answers.
struct DailyView: View {
  /// The sizing arithmetic, which lives in `CoreLogic` so it can be tested
  /// without a window — see `DailyChecklistLayout`. `PopoverLayout` reads the
  /// same type when it decides how tall the panel should be.
  typealias Layout = DailyChecklistLayout

  @Environment(AppCoordinator.self) var manager

  @State private var hoveredBucketIndex: Int?
  /// Owned by the view rather than the manager: the router only needs to say
  /// "open the field", and where the caret goes after that is a view concern.
  @FocusState private var addFieldFocused: Bool
  /// Separate from `addFieldFocused` because the two fields can never be open
  /// at once but *can* hand over to each other, and one shared flag would leave
  /// the incoming field fighting the outgoing one for first responder.
  @FocusState private var editFieldFocused: Bool

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var dailyLog: DailyLogManager { manager.dailyLog }

  var body: some View {
    // Read `revision` so recording an event re-renders the projections. The
    // log itself lives in the plugin and isn't observable — see DailyLogManager.
    // `let _ =`, not `_ =`: inside a ViewBuilder the latter is parsed as a
    // view expression and fails to compile. swiftlint:disable:next redundant_discardable_let
    let _ = dailyLog.revision

    // No horizontal padding on the container: the dailies rows are full-bleed
    // like the task rows elsewhere, so their selection highlight reaches the
    // panel edge instead of floating in an inset box. Everything else insets
    // itself to the same `rowHorizontalPadding`.
    VStack(alignment: .leading, spacing: 10) {
      // The checklist starts the view — the first thing in the panel is a row
      // you can tick. Two things used to sit above it and neither survived: a
      // running "N done today" line with its focused/dailies/left chips, which
      // was a scoreboard for a question the rows underneath already answer one
      // by one, and a "DAILIES" header strip, which captioned a view the dock
      // has already named and put the only add button somewhere the keyboard
      // never goes. Adding is Return, which is where the empty hint points.
      dailiesSection
      // Hidden from the dock's graph button, which makes this a plain
      // checklist for days you're only ticking things off.
      if manager.popoverChrome.showsDailyChart {
        Divider()
        chartSection
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      }
      // Off unless the dock's list button is on. This view answers "what do I
      // do every day"; what you happened to close in the All list is a
      // different question, and having it always stacked underneath made the
      // checklist look like a footnote to it.
      if PopoverLayout.dailyShowsCompletions(for: manager) {
        Divider()
        completionsList(dailyLog.summary())
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      }
    }
    // Top only, and no trailing `Spacer`. A spacer of zero height still costs
    // the stack's 10pt spacing in front of it, so the two together left 20pt of
    // bare panel under the checklist — a grey bar between the last row and the
    // dock that no amount of sizing the list differently could remove.
    .padding(.top, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Dailies

  /// Today's recurring intentions, as a checklist.
  ///
  /// Built from the same measurements as `PopoverView.taskRow` — 13pt in the
  /// user's chosen task font, `PopoverLayout` row padding, full-bleed selection
  /// with the 3pt leading bar. These rows sit in the same popover as the task
  /// list and are read the same way, so they have no business being a smaller,
  /// separate visual language.
  @ViewBuilder
  private var dailiesSection: some View {
    let dailies = dailyLog.todaysDailies
    let completed = dailyLog.completedDailyIds()

    VStack(alignment: .leading, spacing: 0) {
      if dailies.isEmpty && !dailyLog.isAddingDaily {
        emptyDailiesHint
      } else {
        // `ScrollViewReader`, because the selection is moved by the keyboard
        // from `KeyboardShortcutRouter` and the list has no idea it happened.
        // Without this, j/↓ walks the cursor straight off the bottom of a
        // clipped list and the view sits still while it goes.
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(dailies.enumerated()), id: \.element.id) { index, daily in
                dailyRow(
                  daily,
                  isDone: completed.contains(daily.id),
                  isSelected: index == dailyLog.selectedDailyIndex
                )
                .id(daily.id)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          // Fills whatever room is left, and scrolls. Not a fixed height and
          // not a computed one: either leaves a strip of bare panel under the
          // last row, or overflows the window and pushes the dock off the
          // bottom. The eight-row cap lives in `preferredRowsHeight`, where it
          // decides how tall the *panel* gets when nothing has been dragged —
          // applying it here as well would cap a panel you deliberately dragged
          // taller, leaving the extra as dead space.
          .frame(maxHeight: .infinity)
          .onChange(of: dailyLog.selectedDailyIndex) { _, index in
            guard dailies.indices.contains(index) else { return }
            // No anchor: scroll the minimum needed to bring the row into view,
            // so walking down a list moves it a row at a time rather than
            // yanking the selection to the middle on every keypress.
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(dailies[index].id)
            }
          }
        }
      }

      if dailyLog.isAddingDaily {
        addDailyField
      }
    }
  }

  @ViewBuilder
  private func dailyRow(_ daily: Daily, isDone: Bool, isSelected: Bool) -> some View {
    let kind = CompletionKind.daily(id: daily.id)
    let isEditing = dailyLog.editingDailyId == daily.id
    // The tint/scale/strike half of the active preset only. A ticked daily
    // *stays* in the list, unlike a completed task, so the collapse-and-fade
    // half would fold the row shut and then spring it straight back.
    let treatment = manager.celebration.rowTreatment
    let reduceMotion = manager.celebration.prefersReducedMotion

    HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
      // Fixed-width icon slot, so titles line up with each other and with the
      // task rows in the other views rather than shifting with the glyph.
      CelebrationStatusGlyph(isDone: isDone, kind: kind)

      if isEditing {
        editDailyField
      } else {
        Text(daily.title)
          .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
          // Struck through *and* muted, so doneness never rests on colour alone.
          //
          // Only one of the two strikes ever renders. Where the preset draws
          // its own rule, this boolean one is off entirely — running both put
          // two lines on the row: SwiftUI sets its strikethrough near the
          // x-height while a rule centred on the text frame lands a couple of
          // points lower, so as the celebration ended the drawn line retracted
          // leftwards *underneath* the native one that had just snapped in.
          // That trailing second line was the "extra line" the tick appeared to
          // leave behind.
          .strikethrough(isDone && !treatment.drawsStrikethrough, color: themeColor(.textMuted))
          .foregroundColor(isDone ? themeColor(.textMuted) : themeColor(.textPrimary))
          .lineLimit(1)
          .truncationMode(.tail)
          .overlay(alignment: .center) {
            // The same drawn rule the task rows use, rather than the boolean
            // `.strikethrough` — a modifier SwiftUI cannot interpolate, and so
            // cannot animate. Presets that say removal is the effect opt out.
            //
            // Driven by `isDone`, not by the celebration phase: on a daily the
            // strike is the *lasting* state, not a flourish that plays over
            // one. Tying it to the celebration flag meant it drew in and then
            // wound itself back out 180ms later. `.animation(_:value:)` still
            // animates the draw, because `isDone` is what changes when the row
            // is ticked.
            if treatment.drawsStrikethrough {
              CelebrationStrike(
                isDrawn: isDone,
                color: manager.celebration.phase(for: kind) == .celebrating
                  ? themeColor(.success).opacity(0.65)
                  : themeColor(.textMuted),
                reduceMotion: reduceMotion
              )
            }
          }
      }

      Spacer(minLength: 0)

      // Hidden while renaming: the field wants the width, and a schedule badge
      // is not something you can act on from the keyboard mid-edit anyway.
      if !daily.isEveryDay && !isEditing {
        Text(daily.scheduleLabel)
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(themeColor(.textSecondary))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(themeColor(.panelSurfaceElevated))
          )
      }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    // A fixed height, not padding: the schedule badge is a point taller than a
    // bare title, so padded rows come out 34 or 35 depending on their content
    // and the list stops landing on a clean grid.
    .frame(height: Layout.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    // A ticked daily stays in the list, so it never folds shut — the collapse
    // would spring straight back the moment the celebration ended.
    .celebrating(
      kind,
      selectionBackground: isSelected ? themeColor(.selectionBackground).opacity(0.7) : nil,
      selectionBar: isSelected ? themeColor(.selectionForeground) : nil,
      allowsCollapse: false
    )
    .contentShape(Rectangle())
    // Click selects *and* ticks, because a daily has nothing else you'd click
    // it for — unlike a task row, where selection and completion are distinct.
    // Not while renaming, though: a click into the field would tick the thing
    // you are in the middle of naming.
    .onTapGesture {
      activateDaily(daily, isEditing: isEditing)
    }
    // The workspace embeds this checklist without the menu-bar key router.
    // A focusable row keeps its toggle reachable even when macOS Keyboard
    // Navigation is disabled and native buttons are skipped by Tab.
    .focusable(!isEditing)
    .onKeyPress(keys: [.space, .return]) { _ in
      guard !isEditing else { return .ignored }
      activateDaily(daily, isEditing: isEditing)
      return .handled
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(daily.title), \(isDone ? "done" : "not done")")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default) { activateDaily(daily, isEditing: isEditing) }
  }

  private func activateDaily(_ daily: Daily, isEditing: Bool) {
    guard !isEditing else { return }
    dailyLog.selectDaily(daily)
    dailyLog.toggleDaily(daily)
  }

  /// Renaming a daily in place.
  ///
  /// A draft in the manager rather than a binding straight through to the
  /// store. Writing every keystroke through was how the settings editor did it,
  /// and it could not be typed in: the store trims what it is handed and
  /// rejects an empty result, so a trailing space was swallowed the moment it
  /// was typed and clearing the field snapped the old name back. See
  /// `DailyTitleEdit`.
  @ViewBuilder
  private var editDailyField: some View {
    @Bindable var log = manager.dailyLog
    TextField("Daily name", text: $log.editingDailyTitle)
      .textFieldStyle(.plain)
      .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
      .foregroundColor(themeColor(.textPrimary))
      .focused($editFieldFocused)
      .onSubmit { log.commitDailyEdit() }
      // The fallback, not the mechanism — the popover's key router sees Escape
      // first. Same arrangement as the add field above.
      .onExitCommand { log.cancelDailyEdit() }
      .onAppear { editFieldFocused = true }
      // Clicking away commits rather than discarding. Abandoning what someone
      // just typed because they reached for the mouse is the wrong default;
      // Escape is there for when discarding is what they meant.
      .onChange(of: editFieldFocused) { _, focused in
        if !focused { log.commitDailyEdit() }
      }
  }

  @ViewBuilder
  private var emptyDailiesHint: some View {
    Text("Nothing recurring yet. Press Return to add something you do every day.")
      .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
      .foregroundColor(themeColor(.textMuted))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
      .padding(.vertical, PopoverLayout.rowVerticalPadding)
      .focusable()
      .onKeyPress(keys: [.return, .space]) { _ in
        dailyLog.isAddingDaily = true
        return .handled
      }
  }

  @ViewBuilder
  private var addDailyField: some View {
    @Bindable var log = manager.dailyLog
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
        Image(systemName: "plus")
          .font(.system(size: 14))
          .foregroundColor(themeColor(.textSecondary))
          .frame(width: PopoverLayout.rowIconWidth)
        TextField("New daily", text: $log.newDailyTitle)
          .textFieldStyle(.plain)
          .font(Typography.taskFont(size: 13, name: manager.preferences.appFontName))
          .foregroundColor(themeColor(.textPrimary))
          .focused($addFieldFocused)
          // Return keeps the field open so a routine can be typed in one go;
          // Escape is the way out. Adding five habits shouldn't need five clicks.
          //
          // `onExitCommand` is the fallback, not the mechanism: the popover's
          // key router sees Escape first and cancels there. This stays for the
          // case where the field is focused without that router in play.
          .onSubmit { log.commitNewDaily() }
          .onExitCommand { log.cancelAddingDaily() }
          .onAppear { addFieldFocused = true }

        newDailyScheduleMenu

        Button {
          log.cancelAddingDaily()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(themeColor(.textSecondary))
        }
        .buttonStyle(.plain)
        .focusable()
        .help("Cancel (Esc)")
        .accessibilityLabel("Cancel adding a daily")
      }
      Text("Return adds · Esc cancels")
        .font(.system(size: 10))
        .foregroundColor(themeColor(.textMuted))
        .padding(.leading, PopoverLayout.rowIconWidth + PopoverLayout.rowContentSpacing)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.inlineEntryVerticalPadding)
    .background(themeColor(.panelSurfaceElevated))
  }

  /// The handful of schedules worth choosing *while typing a habit down*.
  ///
  /// Arbitrary weekday sets and arbitrary intervals live in
  /// `Preferences → Plugins → Daily Log`, which is the full editor. Putting
  /// seven day toggles and a stepper in this row would make the fast path —
  /// type a name, press Return — the slow one.
  @ViewBuilder
  private var newDailyScheduleMenu: some View {
    let log = manager.dailyLog
    let choices: [Daily.Schedule] = [
      .weekdays(Daily.allWeekdays),
      .weekdays(Daily.mondayToFriday),
      .weekdays(Daily.weekend),
      .everyNDays(2),
      .everyNDays(3),
      .everyNDays(7),
    ]

    Menu {
      ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
        Button {
          log.newDailySchedule = choice
        } label: {
          if log.newDailySchedule == choice {
            Label(Daily.scheduleLabel(for: choice), systemImage: "checkmark")
          } else {
            Text(Daily.scheduleLabel(for: choice))
          }
        }
      }
    } label: {
      Text(Daily.scheduleLabel(for: log.newDailySchedule))
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(themeColor(.textSecondary))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .focusable()
    .fixedSize()
    .help("How often the new daily repeats")
  }

  // MARK: - Chart

  /// Always drawn, from the first day.
  ///
  /// It used to be withheld until there were 14 days to plot, on the reasoning
  /// that a near-empty chart reads as broken. That was wrong: a flat run of
  /// days is a true statement about a history that has just started, and
  /// hiding it makes the view look unfinished instead. The "collecting since"
  /// line stays underneath while the window isn't full, so the flatline is
  /// explained rather than merely tolerated.
  @ViewBuilder
  private var chartSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      rangePicker
      chart(buckets: dailyLog.chartBuckets())
      if !dailyLog.hasFullChartHistory {
        Text(collectingSubtitle)
          .font(.system(size: 11))
          .foregroundColor(themeColor(.textMuted))
          .lineLimit(1)
      }
    }
  }

  /// One filter row above the chart, per the range it scopes.
  @ViewBuilder
  private var rangePicker: some View {
    HStack(spacing: 4) {
      Text(hoverLabel ?? "Dailies per \(dailyLog.chartRange.bucketNoun)")
        .font(.system(size: 12))
        .foregroundColor(themeColor(.textSecondary))
        .lineLimit(1)
      Spacer(minLength: 8)
      ForEach(DailyChartRange.allCases) { range in
        Button {
          dailyLog.chartRange = range
          hoveredBucketIndex = nil
        } label: {
          Text(range.title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              dailyLog.chartRange == range
                ? themeColor(.selectionBackground) : Color.clear
            )
            .foregroundColor(
              dailyLog.chartRange == range
                ? themeColor(.selectionForeground) : themeColor(.textMuted)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(range.accessibilityTitle)
      }
    }
  }

  /// A plot: one marker per bucket, joined by a hairline.
  ///
  /// Columns before this, on the reasoning that a line slopes through days
  /// nothing happened on. It does — and that is what a run of days *is*. Bars
  /// at the 90-day range are a picket fence a point wide, where the shape of
  /// the trend is exactly what you are looking at the chart for; markers on a
  /// line keep that shape legible at every range, and a zero still reads as a
  /// marker sitting on the baseline rather than as a gap in the fence.
  ///
  /// One hue for every marker — position already encodes magnitude, so shading
  /// higher points darker would double-encode it and spend the only free
  /// channel on information the chart already shows. That channel goes to
  /// emphasis instead: today is the accent, every prior bucket is recessive,
  /// because the question is "today versus my normal".
  @ViewBuilder
  private func chart(buckets: [DayLogAggregator.Bucket]) -> some View {
    let maxCount = max(buckets.map(\.completed).max() ?? 0, 1)

    GeometryReader { proxy in
      // Inset by the largest marker, so the first and last points sit inside
      // the frame instead of being sliced in half by its edges.
      let inset = Self.todayDotRadius
      let plotWidth = max(1, proxy.size.width - inset * 2)
      let plotHeight = max(1, proxy.size.height - inset * 2)
      let count = max(buckets.count, 1)
      // A single bucket has no step to speak of and belongs in the middle
      // rather than pinned to the left edge.
      let step = count > 1 ? plotWidth / CGFloat(count - 1) : 0
      let points = buckets.enumerated().map { index, bucket in
        CGPoint(
          x: inset + (count > 1 ? step * CGFloat(index) : plotWidth / 2),
          y: inset + plotHeight
            - CGFloat(bucket.completed) / CGFloat(maxCount) * plotHeight
        )
      }
      let hitWidth = proxy.size.width / CGFloat(count)

      ZStack {
        // Under the markers, so a dot never sits on a stroke that stops halfway
        // across it. Round joins because the series is spiky by nature and
        // mitred corners at a 90-day range come out as spikes of their own.
        Path { path in
          guard let first = points.first else { return }
          path.move(to: first)
          for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(
          themeColor(.textMuted).opacity(0.4),
          style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        )

        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
          let isLast = index == points.count - 1
          let isHovered = index == hoveredBucketIndex
          let radius = isLast || isHovered ? Self.todayDotRadius : Self.dotRadius
          Circle()
            .fill(
              isLast || isHovered
                ? themeColor(.focusRing) : themeColor(.textMuted).opacity(0.55)
            )
            .frame(width: radius * 2, height: radius * 2)
            .position(point)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .overlay(alignment: .bottom) {
        // Solid hairline baseline, no gridlines — at this size a grid is noise,
        // and dashing it would read as a threshold that isn't there.
        Rectangle()
          .fill(themeColor(.panelDivider))
          .frame(height: 1)
      }
      // Full-height hit columns rather than the markers themselves: a 5pt dot
      // is not something you can reliably put a pointer on, and at the 90-day
      // range the gaps between them would swallow most of the row.
      .overlay {
        HStack(spacing: 0) {
          ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
            Color.clear
              .frame(width: hitWidth)
              .contentShape(Rectangle())
              .onHover { inside in
                hoveredBucketIndex =
                  inside ? index : (hoveredBucketIndex == index ? nil : hoveredBucketIndex)
              }
              .accessibilityLabel(
                "\(bucketLabel(bucket)): \(DayLogFormatting.pluralised(bucket.completed, "daily", "dailies"))"
              )
          }
        }
      }
    }
    .frame(height: Layout.chartHeight)
  }

  /// Small enough that ninety of them don't merge into a rule, large enough to
  /// read as a plotted point rather than as noise on the line.
  private static let dotRadius: CGFloat = 2
  /// Today, and whatever the pointer is on — the one marker you're meant to
  /// find without reading the label.
  private static let todayDotRadius: CGFloat = 3.5

  private var hoverLabel: String? {
    guard let index = hoveredBucketIndex else { return nil }
    let buckets = dailyLog.chartBuckets()
    guard buckets.indices.contains(index) else { return nil }
    let bucket = buckets[index]
    return "\(bucketLabel(bucket)) — \(DayLogFormatting.pluralised(bucket.completed, "ticked", "ticked"))"
  }

  // Built once rather than per call: `bucketLabel` runs inside every bar's
  // accessibility label, so at the 90-day range a per-call formatter would mean
  // ninety allocations on each render. Same pattern as `ObsidianSyncService`.
  private static let dayLabelFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "EEE d MMM"
    return formatter
  }()

  /// Used for week-commencing labels and for the "collecting since" date.
  private static let shortDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "d MMM"
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  private func bucketLabel(_ bucket: DayLogAggregator.Bucket) -> String {
    guard dailyLog.chartRange.isWeekly else {
      return Self.dayLabelFormatter.string(from: bucket.day)
    }
    return "w/c \(Self.shortDayFormatter.string(from: bucket.day))"
  }

  /// Shown under the chart while the window still reaches back further than the
  /// log does, so the flat left-hand side reads as "nothing recorded yet"
  /// rather than as "nothing done".
  private var collectingSubtitle: String {
    guard let firstDay = dailyLog.firstRecordedDay else {
      return "No history yet — today is day one."
    }
    return "Collecting since \(Self.shortDayFormatter.string(from: firstDay))."
  }

  // MARK: - Completions

  @ViewBuilder
  private func completionsList(_ summary: DayLogAggregator.DaySummary) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("DONE TODAY")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
        .padding(.bottom, 5)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          // Most recent first: the bottom of a long day is the part you're
          // actually checking.
          ForEach(Array(summary.completed.reversed().enumerated()), id: \.offset) { _, event in
            HStack(alignment: .center, spacing: 8) {
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeColor(.success))
                .frame(width: PopoverLayout.rowIconWidth)
              Text(event.title.isEmpty ? "(untitled)" : event.title)
                .font(Typography.taskFont(size: 12, name: manager.preferences.appFontName))
                .foregroundColor(themeColor(.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 0)
              Text(timeLabel(event.at))
                .font(.system(size: 11))
                .foregroundColor(themeColor(.textMuted))
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 96)
    }
  }

  private func timeLabel(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}
