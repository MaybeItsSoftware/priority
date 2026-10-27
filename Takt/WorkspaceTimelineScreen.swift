import TaktCore
import TaktWorkspace
import SwiftUI

/// The timeline: a day of focused work drawn against the clock, in the bottom
/// dock.
///
/// The hours run left to right across the dock's width and each block is a
/// bar along them, so a short, wide dock holds a whole working day; the day's
/// figures and the breakdown by task sit in a column on the right. It was a
/// column of the right dock once, with the hours running down it, and at that
/// width the figures wrapped a letter at a time and two blocks a few seconds
/// apart drew their titles over each other. The question it answers — where
/// did today actually go — is asked by comparing the shape of the day with
/// the shape you expected, so the gaps have to be as legible as the blocks:
/// what you did not work on is the finding.
struct WorkspaceTimelineScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager

  /// The narrowest an hour is drawn. Below it the hours scroll sideways rather
  /// than squeeze, so a ten-minute block stays a bar rather than a rule.
  private static let minimumHourWidth: CGFloat = 56
  /// The strip along the top the hour labels sit in.
  private static let axisHeight: CGFloat = 18
  /// A row of blocks: tall enough for a line of caption text, short enough
  /// that four rows fit the dock at its default height.
  private static let rowHeight: CGFloat = 22
  private static let rowGap: CGFloat = 3
  /// The shortest a block is drawn, so a block of a few seconds still shows.
  private static let minimumBlockWidth: CGFloat = 4
  /// Below this a block has no room for its title, and shows none; the
  /// tooltip and the breakdown name it.
  private static let titledBlockWidth: CGFloat = 28
  /// The column on the right: the day's figures, then the tasks.
  private static let sideWidth: CGFloat = 260

  var body: some View {
    day
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.paper)
      .onAppear { model.reloadFocus() }
      .onChange(of: model.focusHistoryDate) { _, _ in model.reloadFocus() }
  }

  /// Almost all of the day is a finished record and does not care what time
  /// it is, so it is not redrawn on a clock. Two things move: the running
  /// block, which grows by the second, and the "now" rule, which moves about
  /// a point a minute. Each carries its own `TimelineView` — see `placed` and
  /// `nowRule` — so a tick redraws one bar rather than the whole chart.
  ///
  /// The one exception is the minute: while a block runs, the day is
  /// reassembled once a minute so the totals and the rows take its growth.
  @ViewBuilder private var day: some View {
    if isRunningToday {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        content(now: context.date)
      }
    } else {
      content(now: .now)
    }
  }

  /// A block is running on the day on screen, and actually accruing time.
  private var isRunningToday: Bool {
    guard model.timelineShowsToday, let session = model.activeFocusSession else { return false }
    return session.pausedAt == nil && session.activeTaskId != nil
  }

  // MARK: - The day

  @ViewBuilder
  private func content(now: Date) -> some View {
    let day = TimelineDay(model: model, now: now, theme: theme)
    HStack(spacing: 0) {
      chart(day)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Rectangle()
        .fill(theme.border)
        .frame(width: theme.hairline)
      VStack(alignment: .leading, spacing: 0) {
        summary(day)
        FocusRule()
        breakdown(day)
      }
      .frame(width: Self.sideWidth)
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  /// The day's figures on one line, never wrapped: the less telling ones drop
  /// off before anything breaks mid-word.
  private func summary(_ day: TimelineDay) -> some View {
    let focused = figure(duration(day.totalSeconds), "focused")
    let blocks = figure("\(day.blocks.count)", day.blocks.count == 1 ? "block" : "blocks")
    let longest = figure(day.longestLabel, "longest")
    let points = scoredPoints(day).map { figure(FocusPoints.formatted($0), "pts") }
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: theme.space.md) { focused; blocks; longest; points }
      HStack(spacing: theme.space.md) { focused; blocks; points }
      HStack(spacing: theme.space.md) { focused; blocks }
      focused
    }
    .font(theme.monoCaptionFont)
    .monospacedDigit()
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, theme.paneGutter)
    .padding(.vertical, theme.space.xs)
    .help("Active work time; pauses are not drawn, so a block paused mid-way reads as one span.")
  }

  /// Points for the day, or nil when there are none to show. Scoring off
  /// means no points, even for days that were scored.
  private func scoredPoints(_ day: TimelineDay) -> Double? {
    guard manager.preferences.scoresEachFocusBlock else { return nil }
    if day.isToday { return model.focusPoints.today }
    return day.scoredPoints > 0 ? day.scoredPoints : nil
  }

  private func figure(_ value: String, _ caption: String) -> some View {
    HStack(spacing: theme.space.xxs) {
      Text(value).foregroundStyle(theme.ink)
      Text(caption).foregroundStyle(theme.muted)
    }
    .fixedSize()
  }

  /// The hours across, the blocks along them in as many rows as their drawn
  /// lengths need. The width is shared out between the hours down to a
  /// floor, and past it the chart scrolls sideways; rows past the dock's
  /// height scroll down.
  private func chart(_ day: TimelineDay) -> some View {
    GeometryReader { geometry in
      let gutter = theme.paneGutter
      let hours = CGFloat(day.layout.hourCount)
      let hourWidth = max(Self.minimumHourWidth, (geometry.size.width - gutter * 2) / hours)
      let rows = drawnRows(day, hourWidth: hourWidth)
      let rowsHeight = CGFloat(rows.count) * (Self.rowHeight + Self.rowGap)
      let height = max(geometry.size.height, Self.axisHeight + theme.space.xs + rowsHeight + theme.space.sm)
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          hourGrid(day.layout, hourWidth: hourWidth, height: height)
            .offset(x: gutter)
          ForEach(day.layout.placements) { placement in
            placed(placement, day: day, hourWidth: hourWidth)
              .offset(
                x: gutter + CGFloat(placement.offsetMinutes) / 60 * hourWidth,
                y: Self.axisHeight + theme.space.xs
                  + CGFloat(rows.rows[placement.id] ?? 0) * (Self.rowHeight + Self.rowGap))
          }
          nowRule(day, hourWidth: hourWidth, height: height)
            .offset(x: gutter)
        }
        .frame(width: hourWidth * hours + gutter * 2, height: height, alignment: .topLeading)
      }
      .scrollIndicators(.automatic)
      .defaultScrollAnchor(day.isToday ? .topTrailing : .topLeading)
    }
    .overlay {
      if day.blocks.isEmpty {
        // Over the grid rather than in place of it: an empty day still has a
        // shape, and saying so against the hours reads as "nothing here yet"
        // rather than as a pane that failed to load.
        Text(day.isToday ? "No focus time recorded yet today." : "No focus time recorded on this day.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .padding(.horizontal, theme.space.sm)
          .padding(.vertical, theme.space.xs)
          .background(theme.paper)
      }
    }
  }

  /// Each block's row, from its drawn extent: start to the end of whichever
  /// is longer, the bar or the room its title needs.
  private func drawnRows(_ day: TimelineDay, hourWidth: CGFloat) -> (rows: [String: Int], count: Int) {
    let spans = day.layout.placements.map { placement in
      let start = Double(CGFloat(placement.offsetMinutes) / 60 * hourWidth)
      return (start: start, end: start + Double(blockWidth(minutes: placement.minutes, hourWidth: hourWidth)))
    }
    let packed = FocusDayTimeline.drawnRows(spans: spans, gap: Double(Self.rowGap))
    let rows = Dictionary(
      zip(day.layout.placements.map(\.id), packed.rows), uniquingKeysWith: { first, _ in first })
    return (rows, packed.count)
  }

  private func blockWidth(minutes: Double, hourWidth: CGFloat) -> CGFloat {
    max(Self.minimumBlockWidth, CGFloat(minutes) / 60 * hourWidth - 1)
  }

  /// A rule down from each hour, its label just after it along the top.
  /// Placed by offset rather than stacked, because a stack would let the
  /// label's width decide the spacing between hours — and the spacing is the
  /// scale everything else on the chart is drawn to.
  private func hourGrid(_ layout: FocusDayTimeline.Layout, hourWidth: CGFloat, height: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(layout.hours.enumerated()), id: \.offset) { index, hour in
        let x = CGFloat(index) * hourWidth
        Rectangle()
          .fill(theme.borderMuted)
          .frame(width: theme.hairline, height: height)
          .offset(x: x)
        if index < layout.hourCount {
          Text(hour, format: .dateTime.hour())
            .font(theme.monoCaptionFont)
            .monospacedDigit()
            .foregroundStyle(theme.dim)
            .lineLimit(1)
            .fixedSize()
            .frame(height: Self.axisHeight)
            .offset(x: x + theme.space.xxs)
        }
      }
    }
  }

  /// A block at its place. The running one ticks on its own, so the second
  /// hand redraws one bar and nothing else: its start is fixed, so only its
  /// length has to follow the clock.
  @ViewBuilder
  private func placed(_ placement: FocusDayTimeline.Placement, day: TimelineDay, hourWidth: CGFloat) -> some View {
    if placement.block.isLive, isRunningToday, let session = model.activeFocusSession {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let minutes = max(placement.minutes, Double(session.elapsedSeconds(now: context.date)) / 60)
        block(placement, minutes: minutes, day: day, hourWidth: hourWidth)
      }
    } else {
      block(placement, minutes: placement.minutes, day: day, hourWidth: hourWidth)
    }
  }

  /// A block is the status convention in its task's hue: a tinted fill, a
  /// border and an edge of the same colour. The running one is the same shape
  /// with the border at full strength, so "live" reads without a second style.
  /// Its text is clipped to it, so a short block never writes over the next.
  private func block(
    _ placement: FocusDayTimeline.Placement, minutes: Double, day: TimelineDay, hourWidth: CGFloat
  ) -> some View {
    let hue = day.colour(for: placement.block.id)
    // Scoring off means no points on the timeline either, scored days included.
    let award = manager.preferences.scoresEachFocusBlock ? model.focusHistoryAwards[placement.block.id] : nil
    let isLive = placement.block.isLive
    let width = blockWidth(minutes: minutes, hourWidth: hourWidth)
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    return HStack(spacing: theme.space.xs) {
      if width >= Self.titledBlockWidth {
        Text(placement.block.title)
          .foregroundStyle(theme.ink)
          .layoutPriority(1)
        Text(duration(Int(minutes * 60)))
          .monospacedDigit()
          .foregroundStyle(theme.muted)
      }
    }
    .font(theme.captionFont)
    .lineLimit(1)
    .padding(.horizontal, theme.space.xs)
    .frame(width: width, height: Self.rowHeight, alignment: .leading)
    .background(hue.opacity(isLive ? Theme.statusFillOpacity * 2 : Theme.statusFillOpacity))
    .overlay(alignment: .leading) {
      Rectangle().fill(hue).frame(width: min(theme.emphasisBorder, width))
    }
    .clipShape(shape)
    .overlay(
      shape.strokeBorder(
        hue.opacity(isLive ? 1 : Theme.statusBorderOpacity),
        lineWidth: isLive ? theme.emphasisBorder : theme.hairline))
    .contentShape(shape)
    .help(tooltip(placement, minutes: minutes, award: award))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tooltip(placement, minutes: minutes, award: award))
  }

  private func tooltip(_ placement: FocusDayTimeline.Placement, minutes: Double, award: FocusAward?) -> String {
    let end = placement.startedAt.addingTimeInterval(minutes * 60)
    var line = "\(placement.block.title) — \(time(placement.startedAt))–\(time(end)), \(duration(Int(minutes * 60)))"
    if placement.block.isLive { line += " (running)" }
    if let award, manager.preferences.scoresEachFocusBlock {
      line += " · \(award.quality?.title ?? "scored") \(FocusPoints.formatted(award.points)) pts"
    }
    return line
  }

  /// Today only, and ticking by the minute on its own: the rule is the one
  /// thing on a finished day that moves, and it moves about a point a minute.
  @ViewBuilder
  private func nowRule(_ day: TimelineDay, hourWidth: CGFloat, height: CGFloat) -> some View {
    if day.isToday {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let offset = day.nowOffsetMinutes(at: context.date) {
          Rectangle()
            .fill(theme.primary)
            .frame(width: theme.hairline, height: height)
            .offset(x: CGFloat(offset) / 60 * hourWidth)
            .help("Now")
        }
      }
      .allowsHitTesting(false)
    }
  }

  // MARK: - By task

  /// The day by task, and the rows the keyboard walks: ↑ ↓ (or j k) move the
  /// cursor, `o` opens the task in its own list.
  private func breakdown(_ day: TimelineDay) -> some View {
    let cursor = model.timelineCursorSummary(in: day.summaries)?.id
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if day.summaries.isEmpty {
            Text("Nothing logged.")
              .font(theme.captionFont)
              .foregroundStyle(theme.dim)
              .padding(.horizontal, theme.paneGutter)
              .padding(.vertical, theme.space.sm)
          }
          ForEach(day.summaries) { summary in
            breakdownRow(summary, of: day, isCursor: summary.id == cursor)
              .id(summary.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, theme.space.xxs)
      }
      .onChange(of: model.timelineCursorID) { _, id in
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
      }
    }
  }

  /// One line a task: its hue, its title, and its time and share at the end.
  private func breakdownRow(_ summary: TimelineDay.TaskSummary, of day: TimelineDay, isCursor: Bool) -> some View {
    HStack(spacing: theme.space.sm) {
      RoundedRectangle(cornerRadius: 1)
        .fill(day.colour(forTask: summary.id))
        .frame(width: theme.emphasisBorder, height: theme.space.md)
      Text(summary.title)
        .font(theme.captionFont)
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: theme.space.xs)
      Text(shareLine(summary, of: day))
        .font(theme.monoCaptionFont)
        .monospacedDigit()
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.vertical, theme.space.xxs)
    // The whole gutter inside the highlight, as the done rail's rows have it.
    .padding(.horizontal, theme.paneGutter)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: isCursor, hasKeyboard: isCursor && model.keyboardFocusArea == .timeline)
    .onTapGesture {
      model.timelineCursorID = summary.id
      model.reportKeyboardFocus(.timeline)
    }
    .commandHelp(.timelineReveal, note: "\(summary.title) · \(summary.blocks == 1 ? "1 block" : "\(summary.blocks) blocks")")
    .houseContextMenu {
      houseMenuItem("Open where it lives", command: .timelineReveal, on: .outline) { model.revealTimelineTask(summary.id) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.revealTimelineTask(summary.id) }
  }

  private func shareLine(_ summary: TimelineDay.TaskSummary, of day: TimelineDay) -> String {
    let share = day.totalSeconds > 0 ? Int((Double(summary.seconds) / Double(day.totalSeconds) * 100).rounded()) : 0
    return "\(duration(summary.seconds)) · \(share)%"
  }

  // MARK: - Formatting

  private func duration(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
  }

  private func time(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }
}

/// The timeline's end of the bottom dock's tab bar: the day on screen, one
/// line however narrow, and the keys to move it.
struct WorkspaceTimelineDayControls: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    HStack(spacing: theme.space.xxs) {
      Text(model.timelineShowsToday ? "Today" : dayTitle)
        .font(theme.captionFont)
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .fixedSize()
        .padding(.trailing, theme.space.xs)
      WorkspacePaneIconButton("chevron.left", title: "Previous day", command: .timelinePreviousDay) {
        model.moveTimelineDay(by: -1)
      }
      DatePicker("Day", selection: Bindable(model).focusHistoryDate, in: ...Date.now, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.field)
        .font(theme.captionFont)
        .fixedSize()
        // The field's own keys; the day-by-day keys are on the chevrons.
        .help("The day on screen · ↑ ↓ change the part under the caret")
      WorkspacePaneIconButton("chevron.right", title: "Next day", command: .timelineNextDay) {
        model.moveTimelineDay(by: 1)
      }
      .disabled(model.timelineShowsToday)
      WorkspacePaneIconButton("calendar", title: "Back to today", command: .timelineToday) {
        model.showTimelineToday()
      }
      .disabled(model.timelineShowsToday)
    }
  }

  /// Short, so it stays on one line: "Tue 13 Oct".
  private var dayTitle: String {
    model.focusHistoryDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }
}

/// One day's worth of timeline, assembled once per render — which, while a
/// block runs, is once a minute.
///
/// Held as a value rather than computed in the view body so the chart, the
/// summary and the breakdown all describe the same instant — including the
/// running block, which is longer by the time the third of them asks.
private struct TimelineDay {
  let date: Date
  let isToday: Bool
  let blocks: [FocusDayTimeline.Block]
  let layout: FocusDayTimeline.Layout
  let totalSeconds: Int
  let scoredPoints: Double
  let summaries: [TaskSummary]
  /// The calendar day on screen, for placing the "now" rule on it.
  private let dayInterval: DateInterval?
  /// Task key → hue, so a task keeps its colour between the chart and the
  /// breakdown however its blocks are scattered through the day.
  private let hues: [String: Color]
  private let taskKeys: [String: String]

  typealias TaskSummary = FocusDayTimeline.TaskSummary

  @MainActor init(model: WorkspaceViewModel, now: Date, theme: Theme) {
    let calendar = Calendar.current
    date = model.focusHistoryDate
    isToday = calendar.isDateInToday(model.focusHistoryDate)

    let logged = model.focusHistory.filter { $0.seconds > 0 }
    let assembled = model.timelineBlocks(now: now)
    let keys = assembled.taskKeys

    blocks = assembled.blocks
    layout = FocusDayTimeline.layout(blocks: blocks, day: model.focusHistoryDate, calendar: calendar)
    totalSeconds = blocks.reduce(0) { $0 + $1.seconds }
    scoredPoints = logged.compactMap { model.focusHistoryAwards[$0.id]?.points }.reduce(0, +)
    taskKeys = keys
    summaries = FocusDayTimeline.summaries(of: blocks, taskKeys: keys)

    let palette = Self.palette(theme)
    fallbackHue = theme.primary
    hues = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, palette[$0.offset % palette.count]) })

    dayInterval = isToday ? calendar.dateInterval(of: .day, for: model.focusHistoryDate) : nil
  }

  /// Where the "now" rule sits at `now`, in minutes down the ruler, or nil
  /// when now is not on the day or not in the window drawn. A function of the
  /// moment rather than a stored figure, so the rule can tick on its own
  /// without the day being reassembled around it.
  func nowOffsetMinutes(at now: Date) -> Double? {
    guard let dayInterval, dayInterval.contains(now) else { return nil }
    let offset = now.timeIntervalSince(layout.start) / 60
    return offset >= 0 && offset <= Double(layout.hourCount) * 60 ? offset : nil
  }

  var longestLabel: String {
    guard let longest = blocks.map(\.seconds).max(), longest > 0 else { return "—" }
    if longest < 3600 { return "\(longest / 60)m" }
    return "\(longest / 3600)h \((longest % 3600) / 60)m"
  }

  func colour(for blockID: String) -> Color {
    colour(forTask: taskKeys[blockID] ?? blockID)
  }

  func colour(forTask key: String) -> Color {
    hues[key] ?? fallbackHue
  }

  /// Per-task identity colour, which is the one thing the extra hues in the
  /// house palette are for. This was SwiftUI's own `.blue`, `.teal`, `.indigo`
  /// and the rest — stock framework hues, which the style forbids precisely
  /// because they do not flip with the theme and are not on brand.
  ///
  /// Primary leads, so a single-task day reads as the app's own colour, and
  /// danger is left out: a red bar on a chart of work you did says something
  /// this chart does not mean.
  private static func palette(_ theme: Theme) -> [Color] {
    [
      theme.primary, theme.color(.categoricalPurple), theme.success,
      theme.color(.categoricalOrange), theme.color(.categoricalPink), theme.warning,
    ]
  }

  private let fallbackHue: Color
}
