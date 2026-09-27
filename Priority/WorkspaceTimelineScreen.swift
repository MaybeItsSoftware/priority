import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Timeline mode: a day of focused work drawn against the clock.
///
/// It takes the main pane the way focus mode does, and for the same reason.
/// The question it answers — where did today actually go — is asked by
/// comparing the shape of the day with the shape you expected, and a panel
/// floating over the board gives you a dialog-sized slot to do that in. At
/// pane size the gaps are as legible as the blocks, which is most of the
/// point: what you did not work on is the finding.
struct WorkspaceTimelineScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model

  /// Points per hour of ruler. Tall enough that a ten-minute block is still a
  /// visible bar rather than a rule, which is what makes a fragmented morning
  /// look fragmented.
  private static let hourHeight: CGFloat = 72
  /// The gutter the hour labels sit in, to the left of the lanes.
  private static let rulerWidth: CGFloat = 58

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      // Ticking each second keeps the running block growing and the "now" rule
      // moving; everything else on screen is a finished record and does not
      // care what time it is.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        content(now: context.date)
      }
      Divider()
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear { model.reloadFocus() }
    .onChange(of: model.focusHistoryDate) { _, _ in model.reloadFocus() }
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 12) {
      MicroLabel("Timeline")
      dayControls
      Spacer()
      Button("Leave") { model.dismissTimelineScreen() }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
      KeyCap("esc")
    }
    .focusSurfaceBand()
  }

  private var dayControls: some View {
    HStack(spacing: 6) {
      Button { model.moveTimelineDay(by: -1) } label: { Image(systemName: "chevron.left") }
        .buttonStyle(.borderless)
        .accessibilityLabel("Previous day")
      DatePicker("Day", selection: Bindable(model).focusHistoryDate, in: ...Date.now, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.field)
      Button { model.moveTimelineDay(by: 1) } label: { Image(systemName: "chevron.right") }
        .buttonStyle(.borderless)
        .accessibilityLabel("Next day")
        .disabled(model.timelineShowsToday)
      Button("Today") { model.showTimelineToday() }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(model.timelineShowsToday)
    }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Spacer()
      KeyHint("← →", "Change day")
      KeyHint("t", "Today")
      Text("Active work time; pauses are not drawn, so a block paused mid-way reads as one span.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .focusSurfaceBand()
  }

  // MARK: - The day

  @ViewBuilder
  private func content(now: Date) -> some View {
    let day = TimelineDay(model: model, now: now, theme: theme)
    VStack(spacing: 0) {
      summary(day)
      Divider()
      HStack(spacing: 0) {
        chart(day)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        breakdown(day)
          .frame(width: 260)
      }
      .frame(maxHeight: .infinity)
    }
  }

  private func summary(_ day: TimelineDay) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 28) {
      figure(duration(day.totalSeconds), "FOCUSED")
      figure("\(day.blocks.count)", day.blocks.count == 1 ? "BLOCK" : "BLOCKS")
      figure(day.longestLabel, "LONGEST")
      if day.isToday {
        figure("\(FocusPoints.formatted(model.focusPoints.today)) pts", "SCORED")
      } else if day.scoredPoints > 0 {
        figure("\(FocusPoints.formatted(day.scoredPoints)) pts", "SCORED")
      }
      Spacer()
      Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .focusSurfaceGutter()
    .padding(.vertical, 14)
  }

  private func figure(_ value: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title2.weight(.semibold).monospacedDigit())
      Text(caption).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func chart(_ day: TimelineDay) -> some View {
    ScrollView {
      ZStack(alignment: .topLeading) {
        hourGrid(day.layout)
        lanes(day)
        if let offset = day.nowOffsetMinutes { nowRule(atMinutes: offset) }
      }
      .frame(maxWidth: .infinity, minHeight: CGFloat(day.layout.hourCount) * Self.hourHeight + 16, alignment: .topLeading)
      .focusSurfaceGutter()
      .padding(.vertical, 16)
    }
    .overlay {
      if day.blocks.isEmpty {
        // Over the grid rather than in place of it: an empty day still has a
        // shape, and saying so against the hours reads as "nothing here yet"
        // rather than as a screen that failed to load.
        Text(day.isToday ? "No focus time recorded yet today." : "No focus time recorded on this day.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(10)
          .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  /// Rules and labels are placed by offset rather than stacked, because a
  /// stack would let the label's own height decide the spacing between hours
  /// — and the spacing is the scale everything else on the chart is drawn to.
  private func hourGrid(_ layout: FocusDayTimeline.Layout) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(layout.hours.enumerated()), id: \.offset) { index, hour in
        HStack(spacing: 8) {
          Text(hour, format: .dateTime.hour())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: Self.rulerWidth - 8, alignment: .trailing)
          Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: 1)
        }
        .frame(height: 12)
        // Half the row's height, so the label sits centred on its own rule.
        .offset(y: CGFloat(index) * Self.hourHeight - 6)
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
        block(placement, day: day)
          .frame(width: max(10, laneWidth - 4), height: max(14, CGFloat(placement.minutes) / 60 * Self.hourHeight - 2), alignment: .topLeading)
          .offset(
            x: Self.rulerWidth + CGFloat(placement.lane) * laneWidth,
            y: CGFloat(placement.offsetMinutes) / 60 * Self.hourHeight)
      }
    }
  }

  private func block(_ placement: FocusDayTimeline.Placement, day: TimelineDay) -> some View {
    let hue = day.colour(for: placement.block.id)
    let award = model.focusHistoryAwards[placement.block.id]
    return VStack(alignment: .leading, spacing: 1) {
      Text(placement.block.title)
        .font(.caption.weight(.medium))
        .lineLimit(placement.minutes >= 25 ? 3 : 1)
      if placement.minutes >= 12 {
        Text(duration(Int(placement.minutes * 60)) + (award.map { " · \($0.quality?.title ?? FocusPoints.formatted($0.points) + " pts")" } ?? ""))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(hue.opacity(placement.block.isLive ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(hue.opacity(placement.block.isLive ? 0.9 : 0.45), lineWidth: placement.block.isLive ? 1.5 : 1))
    .overlay(alignment: .leading) {
      Rectangle().fill(hue).frame(width: 2).clipShape(RoundedRectangle(cornerRadius: 1))
    }
    .help(tooltip(placement, award: award))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(tooltip(placement, award: award))
  }

  private func tooltip(_ placement: FocusDayTimeline.Placement, award: FocusAward?) -> String {
    var line = "\(placement.block.title) — \(time(placement.startedAt))–\(time(placement.endedAt)), \(duration(Int(placement.minutes * 60)))"
    if placement.block.isLive { line += " (running)" }
    if let award { line += " · \(award.quality?.title ?? "scored") \(FocusPoints.formatted(award.points)) pts" }
    return line
  }

  private func nowRule(atMinutes offset: Double) -> some View {
    HStack(spacing: 0) {
      Text("now")
        .font(.caption2.weight(.bold))
        .foregroundStyle(theme.primary)
        .frame(width: Self.rulerWidth - 8, alignment: .trailing)
        .padding(.trailing, 8)
      Rectangle().fill(theme.primary.opacity(0.8)).frame(height: theme.hairline)
    }
    .offset(y: CGFloat(offset) / 60 * Self.hourHeight)
    .allowsHitTesting(false)
  }

  // MARK: - By task

  private func breakdown(_ day: TimelineDay) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("BY TASK").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
        if day.summaries.isEmpty {
          Text("Nothing logged.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(day.summaries) { summary in
          HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
              .fill(day.colour(forTask: summary.id))
              .frame(width: 3)
              .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
              Text(summary.title).font(.callout).lineLimit(3)
              Text(shareLine(summary, of: day)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
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

/// One day's worth of timeline, assembled once per tick.
///
/// Held as a value rather than computed in the view body so the chart, the
/// summary and the breakdown all describe the same instant — including the
/// running block, which is a second longer by the time the third of them asks.
private struct TimelineDay {
  let date: Date
  let isToday: Bool
  let blocks: [FocusDayTimeline.Block]
  let layout: FocusDayTimeline.Layout
  let totalSeconds: Int
  let scoredPoints: Double
  let summaries: [TaskSummary]
  let nowOffsetMinutes: Double?
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

    if isToday, let interval = calendar.dateInterval(of: .day, for: model.focusHistoryDate), interval.contains(now) {
      let offset = now.timeIntervalSince(layout.start) / 60
      nowOffsetMinutes = offset >= 0 && offset <= Double(layout.hourCount) * 60 ? offset : nil
    } else {
      nowOffsetMinutes = nil
    }
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
