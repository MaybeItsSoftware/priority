import TaktCore
import TaktWorkspace
import SwiftUI

/// Timeline mode: a day of focused work drawn against the clock.
///
/// It takes the main pane rather than floating over it. The question it answers — where did today actually go — is asked by
/// comparing the shape of the day with the shape you expected, and a panel
/// floating over the board gives you a dialog-sized slot to do that in. At
/// pane size the gaps are as legible as the blocks, which is most of the
/// point: what you did not work on is the finding.
struct WorkspaceTimelineScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager

  /// Points per hour of ruler. Tall enough that a ten-minute block is still a
  /// visible bar rather than a rule, which is what makes a fragmented morning
  /// look fragmented.
  private static let hourHeight: CGFloat = 72
  /// The gutter the hour labels sit in, to the left of the lanes.
  private static let rulerWidth: CGFloat = 58
  /// The height of an hour label's row. Placed by offset at half of this, so
  /// the label sits centred on its own rule.
  private static let hourLabelHeight: CGFloat = 12

  var body: some View {
    VStack(spacing: 0) {
      header
      // No footer. It was a second strip along the bottom, above the status
      // bar: two key hints the reference and the palette already carry, and a
      // note about pauses that is now the subtitle's tooltip.
      day
    }
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
  /// reassembled once a minute so the totals and the lanes take its growth.
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

  // MARK: - Chrome

  private var header: some View {
    // The day this is, in the place every other surface puts what you are
    // looking at. The micro-label said "Timeline", which the toolbar toggle and
    // the sidebar row were already saying, and left the date buried in a date
    // picker in the middle of the row.
    WorkspacePaneHeader(title: model.timelineShowsToday ? "Today" : dayTitle) {
      Text("Where the focused time went")
        // What the footer used to say along the bottom, kept where it is asked
        // about: pauses are not drawn, so a paused block reads as one span.
        .help("Active work time; pauses are not drawn, so a block paused mid-way reads as one span.")
    } trailing: {
      dayControls
      WorkspacePaneIconButton("xmark", title: "Leave the timeline", command: .timelineClose) {
        model.dismissTimelineScreen()
      }
    }
  }

  private var dayTitle: String {
    model.focusHistoryDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
  }

  private var dayControls: some View {
    HStack(spacing: theme.space.xxs) {
      WorkspacePaneIconButton("chevron.left", title: "Previous day", command: .timelinePreviousDay) {
        model.moveTimelineDay(by: -1)
      }
      DatePicker("Day", selection: Bindable(model).focusHistoryDate, in: ...Date.now, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.field)
        .font(theme.captionFont)
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

  // MARK: - The day

  @ViewBuilder
  private func content(now: Date) -> some View {
    let day = TimelineDay(model: model, now: now, theme: theme)
    VStack(spacing: 0) {
      summary(day)
      FocusRule()
      HStack(spacing: 0) {
        chart(day)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Rectangle()
          .fill(theme.border)
          .frame(width: theme.hairline)
        breakdown(day)
          .frame(width: 260)
      }
      .frame(maxHeight: .infinity)
    }
  }

  private func summary(_ day: TimelineDay) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xl) {
      figure(duration(day.totalSeconds), "Focused")
      figure("\(day.blocks.count)", day.blocks.count == 1 ? "Block" : "Blocks")
      figure(day.longestLabel, "Longest")
      if !manager.preferences.scoresEachFocusBlock {
        // Scoring is off: no points, even for days that were scored.
      } else if day.isToday {
        figure("\(FocusPoints.formatted(model.focusPoints.today)) pts", "Scored")
      } else if day.scoredPoints > 0 {
        figure("\(FocusPoints.formatted(day.scoredPoints)) pts", "Scored")
      }
      Spacer()
      Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
    }
    .focusSurfaceGutter()
    .padding(.vertical, theme.space.md)
  }

  private func figure(_ value: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      Text(value)
        .font(theme.numeralFont(theme.scale.display))
        .monospacedDigit()
        .foregroundStyle(theme.ink)
      MicroLabel(caption)
    }
  }

  @ViewBuilder
  private func chart(_ day: TimelineDay) -> some View {
    ScrollView {
      ZStack(alignment: .topLeading) {
        hourGrid(day.layout)
        lanes(day)
        nowRule(day)
      }
      .frame(
        maxWidth: .infinity,
        minHeight: CGFloat(day.layout.hourCount) * Self.hourHeight + theme.space.lg,
        alignment: .topLeading)
      .focusSurfaceGutter()
      .padding(.vertical, theme.space.lg)
    }
    .overlay {
      if day.blocks.isEmpty {
        // Over the grid rather than in place of it: an empty day still has a
        // shape, and saying so against the hours reads as "nothing here yet"
        // rather than as a screen that failed to load.
        Text(day.isToday ? "No focus time recorded yet today." : "No focus time recorded on this day.")
          .font(theme.bodyFont())
          .foregroundStyle(theme.muted)
          .padding(.horizontal, theme.space.md)
          .padding(.vertical, theme.space.sm)
          .themedSurface(theme)
      }
    }
  }

  /// Rules and labels are placed by offset rather than stacked, because a
  /// stack would let the label's own height decide the spacing between hours
  /// — and the spacing is the scale everything else on the chart is drawn to.
  private func hourGrid(_ layout: FocusDayTimeline.Layout) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(layout.hours.enumerated()), id: \.offset) { index, hour in
        HStack(spacing: theme.space.sm) {
          Text(hour, format: .dateTime.hour())
            .font(theme.numeralFont(theme.scale.caption, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(theme.dim)
            .frame(width: Self.rulerWidth - theme.space.sm, alignment: .trailing)
          Rectangle()
            .fill(theme.borderMuted)
            .frame(maxWidth: .infinity)
            .frame(height: theme.hairline)
        }
        .frame(height: Self.hourLabelHeight)
        .offset(y: CGFloat(index) * Self.hourHeight - Self.hourLabelHeight / 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func lanes(_ day: TimelineDay) -> some View {
    GeometryReader { geometry in
      // Lanes share the grid's origin: hour zero's rule is drawn at y = 0.
      let width = max(40, geometry.size.width - Self.rulerWidth)
      let laneWidth = width / CGFloat(day.layout.laneCount)
      ForEach(day.layout.placements) { placement in
        placed(placement, day: day, laneWidth: laneWidth)
      }
    }
  }

  /// A block at its place on the ruler. The running one ticks on its own, so
  /// the second hand redraws one bar and nothing else: its start is fixed, so
  /// only its length has to follow the clock.
  @ViewBuilder
  private func placed(_ placement: FocusDayTimeline.Placement, day: TimelineDay, laneWidth: CGFloat) -> some View {
    if placement.block.isLive, isRunningToday, let session = model.activeFocusSession {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let minutes = max(placement.minutes, Double(session.elapsedSeconds(now: context.date)) / 60)
        positioned(placement, minutes: minutes, day: day, laneWidth: laneWidth)
      }
    } else {
      positioned(placement, minutes: placement.minutes, day: day, laneWidth: laneWidth)
    }
  }

  private func positioned(
    _ placement: FocusDayTimeline.Placement, minutes: Double, day: TimelineDay, laneWidth: CGFloat
  ) -> some View {
    block(placement, minutes: minutes, day: day)
      .frame(
        width: max(10, laneWidth - theme.space.xs),
        height: max(14, CGFloat(minutes) / 60 * Self.hourHeight - theme.space.xxs),
        alignment: .topLeading)
      .offset(
        x: Self.rulerWidth + CGFloat(placement.lane) * laneWidth,
        y: CGFloat(placement.offsetMinutes) / 60 * Self.hourHeight)
  }

  /// A block is the status convention in its task's hue: a tinted fill, a
  /// border and an edge of the same colour. The running one is the same shape
  /// with the border at full strength, so "live" reads without a second style.
  private func block(_ placement: FocusDayTimeline.Placement, minutes: Double, day: TimelineDay) -> some View {
    let hue = day.colour(for: placement.block.id)
    // Scoring off means no points on the timeline either, scored days included.
    let award = manager.preferences.scoresEachFocusBlock ? model.focusHistoryAwards[placement.block.id] : nil
    let isLive = placement.block.isLive
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      Text(placement.block.title)
        .font(theme.bodyFont(size: theme.scale.caption))
        .foregroundStyle(theme.ink)
        .lineLimit(minutes >= 25 ? 3 : 1)
      if minutes >= 12 {
        Text(duration(Int(minutes * 60)) + (award.map { " · \($0.quality?.title ?? FocusPoints.formatted($0.points) + " pts")" } ?? ""))
          .font(theme.captionFont)
          .monospacedDigit()
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, theme.space.sm)
    .padding(.vertical, theme.space.xs)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(hue.opacity(isLive ? Theme.statusFillOpacity * 2 : Theme.statusFillOpacity))
    .overlay(alignment: .leading) {
      Rectangle().fill(hue).frame(width: theme.emphasisBorder)
    }
    .clipShape(shape)
    .overlay(
      shape.strokeBorder(
        hue.opacity(isLive ? 1 : Theme.statusBorderOpacity),
        lineWidth: isLive ? theme.emphasisBorder : theme.hairline))
    .help(tooltip(placement, minutes: minutes, award: award))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(tooltip(placement, minutes: minutes, award: award))
  }

  private func tooltip(_ placement: FocusDayTimeline.Placement, minutes: Double, award: FocusAward?) -> String {
    let end = placement.startedAt.addingTimeInterval(minutes * 60)
    var line = "\(placement.block.title) — \(time(placement.startedAt))–\(time(end)), \(duration(Int(minutes * 60)))"
    if placement.block.isLive { line += " (running)" }
    if let award, manager.preferences.scoresEachFocusBlock { line += " · \(award.quality?.title ?? "scored") \(FocusPoints.formatted(award.points)) pts" }
    return line
  }

  /// Today only, and ticking by the minute on its own: the rule is the one
  /// thing on a finished day that moves, and it moves about a point a minute.
  @ViewBuilder
  private func nowRule(_ day: TimelineDay) -> some View {
    if day.isToday {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let offset = day.nowOffsetMinutes(at: context.date) {
          HStack(spacing: 0) {
            Text("now")
              .microLabel(theme, color: theme.primary)
              .frame(width: Self.rulerWidth - theme.space.sm, alignment: .trailing)
              .padding(.trailing, theme.space.sm)
            Rectangle().fill(theme.primary).frame(height: theme.hairline)
          }
          .offset(y: CGFloat(offset) / 60 * Self.hourHeight)
        }
      }
      .allowsHitTesting(false)
    }
  }

  // MARK: - By task

  private func breakdown(_ day: TimelineDay) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        MicroLabel("By task")
        if day.summaries.isEmpty {
          Text("Nothing logged.").font(theme.bodyFont()).foregroundStyle(theme.muted)
        }
        ForEach(day.summaries) { summary in
          HStack(alignment: .top, spacing: theme.space.sm) {
            Rectangle()
              .fill(day.colour(forTask: summary.id))
              .frame(width: theme.emphasisBorder)
              .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: theme.space.xxs) {
              Text(summary.title)
                .font(theme.bodyFont())
                .foregroundStyle(theme.ink)
                .lineLimit(3)
              Text(shareLine(summary, of: day))
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(theme.space.lg)
    }
  }

  private func shareLine(_ summary: TimelineDay.TaskSummary, of day: TimelineDay) -> String {
    let share = day.totalSeconds > 0 ? Int((Double(summary.seconds) / Double(day.totalSeconds) * 100).rounded()) : 0
    let blocks = summary.blocks == 1 ? "1 block" : "\(summary.blocks) blocks"
    return "\(duration(summary.seconds)) · \(share)% · \(blocks)"
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

  struct TaskSummary: Identifiable {
    let id: String
    let title: String
    let seconds: Int
    let blocks: Int
  }

  @MainActor init(model: WorkspaceViewModel, now: Date, theme: Theme) {
    let calendar = Calendar.current
    date = model.focusHistoryDate
    isToday = calendar.isDateInToday(model.focusHistoryDate)

    let logged = model.focusHistory.filter { $0.seconds > 0 }
    var assembled = logged.map {
      FocusDayTimeline.Block(id: $0.id, title: $0.taskTitle, seconds: $0.seconds, endedAt: $0.recordedAt)
    }
    var keys: [String: String] = [:]
    for block in logged { keys[block.id] = block.originalTaskId ?? block.taskId ?? block.taskTitle }

    // The running block has no stored record, so it is drawn from the session:
    // it ends at "now" and grows with it. Only on today — on any other day the
    // session on screen is not the one being read back.
    let live = isToday ? model.activeFocusSession : nil
    let liveSeconds = live?.activeTaskId == nil ? 0 : live?.elapsedSeconds(now: now) ?? 0
    if let live, let task = model.activeFocusTask, liveSeconds > 0 {
      let id = live.activeBlockId ?? "live/\(live.id)"
      assembled.append(FocusDayTimeline.Block(id: id, title: task.title, seconds: liveSeconds, endedAt: now, isLive: true))
      keys[id] = task.id
    }

    blocks = assembled
    layout = FocusDayTimeline.layout(blocks: assembled, day: model.focusHistoryDate, calendar: calendar)
    totalSeconds = assembled.reduce(0) { $0 + $1.seconds }
    scoredPoints = logged.compactMap { model.focusHistoryAwards[$0.id]?.points }.reduce(0, +)
    taskKeys = keys

    let grouped = Dictionary(grouping: assembled) { keys[$0.id] ?? $0.title }
    summaries = grouped.map { key, values in
      TaskSummary(
        id: key, title: values.last?.title ?? "Deleted task",
        seconds: values.reduce(0) { $0 + $1.seconds }, blocks: values.count)
    }
    .sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }

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
