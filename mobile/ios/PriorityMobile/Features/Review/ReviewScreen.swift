import Charts
import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Review: the day's focus on an hour ruler, the work that got done, and the
/// trend over 7, 30 or 90 days.
struct ReviewScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @State private var review: ReviewModel?

  var body: some View {
    Group {
      if let review {
        ReviewContent(review: review)
      } else {
        Color.clear
      }
    }
    .background(theme.paper)
    .navigationTitle("Review")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { WorkspaceToolbar() }
    .onAppear {
      if review == nil { review = ReviewModel(model: model) }
    }
  }
}

/// The identity hues a task takes on the ruler and in the breakdown. Primary
/// first, so a one-task day reads as the app's own colour; never danger.
enum ReviewHues {
  static let roles: [ThemeColorRole] = [
    .primary, .categoricalPurple, .success, .categoricalOrange, .categoricalPink, .warning,
  ]
  static func color(_ index: Int, in theme: Theme) -> Color { theme.color(roles[index % roles.count]) }
}

private struct ReviewContent: View {
  @Environment(\.theme) private var theme
  @Bindable var review: ReviewModel

  var body: some View {
    VStack(spacing: 0) {
      Picker("Section", selection: $review.section) {
        ForEach(ReviewSection.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, theme.space.lg)
      .padding(.vertical, theme.space.sm)
      .accessibilityIdentifier("review.section")
      Hairline()
      switch review.section {
      case .timeline: ReviewTimelineView(review: review)
      case .done: ReviewDoneView(review: review)
      case .progress: ReviewProgressView(review: review)
      }
    }
  }
}

// MARK: - Timeline

private struct ReviewTimelineView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Bindable var review: ReviewModel
  private let hourHeight: CGFloat = 56

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: theme.space.lg) {
        dayPicker
        if let day = review.timeline {
          summary(day)
          ruler(day)
          if !day.summaries.isEmpty { breakdown(day) }
        }
      }
      .padding(theme.space.lg)
    }
    .task(id: QueryKey(revision: model.revision, scope: review.timelineDate)) {
      // A running block grows on the ruler, so today re-reads each minute.
      while !Task.isCancelled {
        await review.loadTimeline()
        guard review.showsToday else { return }
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  private var dayPicker: some View {
    HStack(spacing: theme.space.sm) {
      Button { review.moveDay(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36).hitTarget() }
        .accessibilityLabel("Previous day")
      DatePicker("Day", selection: $review.timelineDate, in: ...Date.now, displayedComponents: .date)
        .labelsHidden()
      Button { review.moveDay(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36).hitTarget() }
        .disabled(review.showsToday)
        .accessibilityLabel("Next day")
      Spacer()
      if !review.showsToday {
        Button("Today") { review.timelineDate = .now }
          .buttonStyle(ThemedButtonStyle(kind: .quiet, compact: true))
      }
    }
    .foregroundStyle(theme.ink)
  }

  private func summary(_ day: TimelineDay) -> some View {
    HStack(spacing: theme.space.xl) {
      stat("Focused", day.totalSeconds > 0 ? Format.duration(day.totalSeconds) : "—")
      stat("Blocks", "\(day.layout.placements.count)")
      stat("Points", FocusPoints.formatted(day.points))
    }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(theme.type.numeralBody).foregroundStyle(theme.ink)
      Text(label).font(theme.type.footnote).foregroundStyle(theme.muted)
    }
  }

  private func ruler(_ day: TimelineDay) -> some View {
    let layout = day.layout
    let height = CGFloat(layout.hourCount) * hourHeight
    return HStack(alignment: .top, spacing: theme.space.sm) {
      // Hour labels.
      ZStack(alignment: .topTrailing) {
        ForEach(Array(layout.hours.enumerated()), id: \.offset) { index, hour in
          Text(hour.formatted(.dateTime.hour()))
            .font(theme.type.numeral)
            .foregroundStyle(theme.muted)
            .offset(y: CGFloat(index) * hourHeight - 7)
        }
      }
      .frame(width: 44, height: height, alignment: .topTrailing)
      GeometryReader { proxy in
        let laneWidth = proxy.size.width / CGFloat(max(1, layout.laneCount))
        ZStack(alignment: .topLeading) {
          ForEach(0...layout.hourCount, id: \.self) { index in
            Rectangle().fill(theme.borderMuted).frame(height: 1)
              .offset(y: CGFloat(index) * hourHeight)
          }
          ForEach(layout.placements) { placement in
            let hue = ReviewHues.color(day.hue(forBlock: placement.id), in: theme)
            let blockHeight = max(6, CGFloat(placement.minutes / 60) * hourHeight)
            VStack(alignment: .leading, spacing: 0) {
              if blockHeight > 20 {
                Text(placement.block.title).font(theme.type.footnote).foregroundStyle(theme.ink).lineLimit(1)
              }
              if blockHeight > 36 {
                Text(Format.duration(placement.block.seconds) + (placement.block.isLive ? " · live" : ""))
                  .font(theme.type.numeral).foregroundStyle(theme.muted)
              }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, theme.space.xxs)
            .frame(width: laneWidth - 4, height: blockHeight, alignment: .topLeading)
            .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: theme.radius.tag))
            .overlay(alignment: .leading) { Rectangle().fill(hue).frame(width: 3) }
            .overlay(RoundedRectangle(cornerRadius: theme.radius.tag).strokeBorder(hue.opacity(0.4), lineWidth: theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.tag))
            .offset(x: CGFloat(placement.lane) * laneWidth, y: CGFloat(placement.offsetMinutes / 60) * hourHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(placement.block.title), \(Format.duration(placement.block.seconds))")
          }
        }
      }
      .frame(height: height)
    }
    .accessibilityIdentifier("review.ruler")
  }

  private func breakdown(_ day: TimelineDay) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("By task").font(theme.type.caption).foregroundStyle(theme.muted).padding(.bottom, theme.space.sm)
      ForEach(day.summaries) { summary in
        HStack(spacing: theme.space.sm) {
          RoundedRectangle(cornerRadius: 2).fill(ReviewHues.color(summary.hue, in: theme)).frame(width: 10, height: 10)
          Text(summary.title).font(theme.type.body).foregroundStyle(theme.ink).lineLimit(1)
          Spacer()
          Text("\(summary.blocks)×").font(theme.type.numeral).foregroundStyle(theme.dim)
          Text(Format.duration(summary.seconds)).font(theme.type.numeral).foregroundStyle(theme.muted)
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, theme.space.sm)
        Hairline(role: .borderMuted)
      }
    }
  }
}

// MARK: - Done

private struct ReviewDoneView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  let review: ReviewModel

  var body: some View {
    List {
      ForEach(review.doneGroups) { group in
        Section {
          ForEach(group.items) { item in
            row(item)
          }
        } header: {
          HStack {
            Text(group.title)
            Spacer()
            Text("\(group.items.count)").font(theme.type.numeral)
          }
          .font(theme.type.caption)
          .foregroundStyle(theme.muted)
          .textCase(nil)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .overlay {
      if review.doneGroups.isEmpty {
        EmptyState(title: "Nothing finished yet", message: "Completed tasks from the last five weeks show here.",
                   systemImage: "checkmark.circle")
      }
    }
    .task(id: model.revision) { await review.loadDone() }
    .accessibilityIdentifier("review.done")
  }

  private func row(_ item: DoneItem) -> some View {
    HStack(spacing: theme.space.md) {
      TaskCheckbox(status: item.task.status)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.task.title).font(theme.type.body).foregroundStyle(theme.muted)
          .strikethrough(item.task.status == .cancelled, color: theme.dim)
          .lineLimit(2)
        Text(item.listName).font(theme.type.footnote).foregroundStyle(theme.dim)
      }
      Spacer()
      if let completed = item.task.completedAt {
        Text(Format.time(completed)).font(theme.type.numeral).foregroundStyle(theme.dim)
      }
    }
    .padding(.vertical, theme.space.xs)
    .contentShape(Rectangle())
    .onTapGesture { review.reveal(item.task, isPad: isPad) }
    .listRowBackground(theme.paper)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button { review.reopen(item.id) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        .tint(theme.primary)
    }
    .contextMenu {
      Button { review.reveal(item.task, isPad: isPad) } label: { Label("Reveal in list", systemImage: "arrow.right.circle") }
      Button { review.reopen(item.id) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
    }
    .accessibilityIdentifier("review.done.\(item.task.title)")
  }
}

// MARK: - Progress

private struct ReviewProgressView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Bindable var review: ReviewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: theme.space.xl) {
        Picker("Period", selection: $review.period) {
          ForEach(TaskProgressPeriod.allCases) { period in
            Text("\(period.days) days").tag(period)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("review.period")
        let progress = review.progress
        HStack(spacing: theme.space.xl) {
          stat("Done", "\(progress.totalCompleted)")
          stat("Added", "\(progress.totalAdded)")
          stat("Net", signed(progress.totalCompleted - progress.totalAdded))
          stat("Focus", Format.duration(progress.focusMinutes * 60))
        }
        chartBlock("Finished and added") {
          Chart(progress.days) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Finished", day.completed))
              .foregroundStyle(theme.success)
              .position(by: .value("Kind", "Finished"))
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Added", day.added))
              .foregroundStyle(theme.dim)
              .position(by: .value("Kind", "Added"))
          }
          .chartXAxis { axis }
          .chartYAxis { yAxis }
        }
        chartBlock("Minutes focused") {
          Chart(progress.days) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.focusMinutes))
              .foregroundStyle(theme.primary)
          }
          .chartXAxis { axis }
          .chartYAxis { yAxis }
        }
        if let best = progress.bestDay {
          Text("Best day: \(best.day.formatted(.dateTime.weekday(.wide).day().month())), \(best.completed) finished")
            .font(theme.type.caption).foregroundStyle(theme.muted)
        }
      }
      .padding(theme.space.lg)
    }
    .task(id: QueryKey(revision: model.revision, scope: review.period)) { await review.loadProgress() }
    .accessibilityIdentifier("review.progress")
  }

  private var axis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
      AxisGridLine().foregroundStyle(theme.borderMuted)
      AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        .font(theme.type.numeral).foregroundStyle(theme.muted)
    }
  }

  private var yAxis: some AxisContent {
    AxisMarks(position: .leading) { _ in
      AxisGridLine().foregroundStyle(theme.borderMuted)
      AxisValueLabel().font(theme.type.numeral).foregroundStyle(theme.muted)
    }
  }

  private func chartBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      Text(title).font(theme.type.caption).foregroundStyle(theme.muted)
      content().frame(height: 180)
    }
    .padding(theme.space.md)
    .cardSurface()
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(theme.type.numeralBody).foregroundStyle(theme.ink)
      Text(label).font(theme.type.footnote).foregroundStyle(theme.muted)
    }
  }

  private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}
