import Charts
import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Review: the day's focus on an hour ruler, the work that got done, and the
/// trend over 7, 30 or 90 days.
struct ReviewScreen: View {
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
    .background(Palette.paper)
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
  static let palette: [Color] = [Palette.primary, Palette.purple, Palette.success, Palette.orange, Palette.pink, Palette.warning]
  static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

private struct ReviewContent: View {
  @Bindable var review: ReviewModel

  var body: some View {
    VStack(spacing: 0) {
      Picker("Section", selection: $review.section) {
        ForEach(ReviewSection.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, Metrics.lg)
      .padding(.vertical, Metrics.sm)
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
  @Environment(WorkspaceModel.self) private var model
  @Bindable var review: ReviewModel
  private let hourHeight: CGFloat = 56

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.lg) {
        dayPicker
        if let day = review.timeline {
          summary(day)
          ruler(day)
          if !day.summaries.isEmpty { breakdown(day) }
        }
      }
      .padding(Metrics.lg)
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
    HStack(spacing: Metrics.sm) {
      Button { review.moveDay(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
        .accessibilityLabel("Previous day")
      DatePicker("Day", selection: $review.timelineDate, in: ...Date.now, displayedComponents: .date)
        .labelsHidden()
      Button { review.moveDay(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
        .disabled(review.showsToday)
        .accessibilityLabel("Next day")
      Spacer()
      if !review.showsToday {
        Button("Today") { review.timelineDate = .now }
          .buttonStyle(ThemedButtonStyle(kind: .quiet, compact: true))
      }
    }
    .foregroundStyle(Palette.ink)
  }

  private func summary(_ day: TimelineDay) -> some View {
    HStack(spacing: Metrics.xl) {
      stat("Focused", day.totalSeconds > 0 ? Format.duration(day.totalSeconds) : "—")
      stat("Blocks", "\(day.layout.placements.count)")
      stat("Points", FocusPoints.formatted(day.points))
    }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(Typeface.numeralBody).foregroundStyle(Palette.ink)
      Text(label).font(Typeface.footnote).foregroundStyle(Palette.muted)
    }
  }

  private func ruler(_ day: TimelineDay) -> some View {
    let layout = day.layout
    let height = CGFloat(layout.hourCount) * hourHeight
    return HStack(alignment: .top, spacing: Metrics.sm) {
      // Hour labels.
      ZStack(alignment: .topTrailing) {
        ForEach(Array(layout.hours.enumerated()), id: \.offset) { index, hour in
          Text(hour.formatted(.dateTime.hour()))
            .font(Typeface.numeral)
            .foregroundStyle(Palette.muted)
            .offset(y: CGFloat(index) * hourHeight - 7)
        }
      }
      .frame(width: 44, height: height, alignment: .topTrailing)
      GeometryReader { proxy in
        let laneWidth = proxy.size.width / CGFloat(max(1, layout.laneCount))
        ZStack(alignment: .topLeading) {
          ForEach(0...layout.hourCount, id: \.self) { index in
            Rectangle().fill(Palette.borderMuted).frame(height: 1)
              .offset(y: CGFloat(index) * hourHeight)
          }
          ForEach(layout.placements) { placement in
            let hue = ReviewHues.color(day.hue(forBlock: placement.id))
            let blockHeight = max(6, CGFloat(placement.minutes / 60) * hourHeight)
            VStack(alignment: .leading, spacing: 0) {
              if blockHeight > 20 {
                Text(placement.block.title).font(Typeface.footnote).foregroundStyle(Palette.ink).lineLimit(1)
              }
              if blockHeight > 36 {
                Text(Format.duration(placement.block.seconds) + (placement.block.isLive ? " · live" : ""))
                  .font(Typeface.numeral).foregroundStyle(Palette.muted)
              }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(width: laneWidth - 4, height: blockHeight, alignment: .topLeading)
            .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) { Rectangle().fill(hue).frame(width: 3) }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hue.opacity(0.4), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
      Text("By task").font(Typeface.caption).foregroundStyle(Palette.muted).padding(.bottom, Metrics.sm)
      ForEach(day.summaries) { summary in
        HStack(spacing: Metrics.sm) {
          RoundedRectangle(cornerRadius: 2).fill(ReviewHues.color(summary.hue)).frame(width: 10, height: 10)
          Text(summary.title).font(Typeface.body).foregroundStyle(Palette.ink).lineLimit(1)
          Spacer()
          Text("\(summary.blocks)×").font(Typeface.numeral).foregroundStyle(Palette.dim)
          Text(Format.duration(summary.seconds)).font(Typeface.numeral).foregroundStyle(Palette.muted)
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, Metrics.sm)
        Hairline(color: Palette.borderMuted)
      }
    }
  }
}

// MARK: - Done

private struct ReviewDoneView: View {
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
            Text("\(group.items.count)").font(Typeface.numeral)
          }
          .font(Typeface.caption)
          .foregroundStyle(Palette.muted)
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
    HStack(spacing: Metrics.md) {
      TaskCheckbox(status: item.task.status)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.task.title).font(Typeface.body).foregroundStyle(Palette.muted)
          .strikethrough(item.task.status == .cancelled, color: Palette.dim)
          .lineLimit(2)
        Text(item.listName).font(Typeface.footnote).foregroundStyle(Palette.dim)
      }
      Spacer()
      if let completed = item.task.completedAt {
        Text(Format.time(completed)).font(Typeface.numeral).foregroundStyle(Palette.dim)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture { review.reveal(item.task, isPad: isPad) }
    .listRowBackground(Palette.paper)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button { review.reopen(item.id) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        .tint(Palette.primary)
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
  @Environment(WorkspaceModel.self) private var model
  @Bindable var review: ReviewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.xl) {
        Picker("Period", selection: $review.period) {
          ForEach(TaskProgressPeriod.allCases) { period in
            Text("\(period.days) days").tag(period)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("review.period")
        let progress = review.progress
        HStack(spacing: Metrics.xl) {
          stat("Done", "\(progress.totalCompleted)")
          stat("Added", "\(progress.totalAdded)")
          stat("Net", signed(progress.totalCompleted - progress.totalAdded))
          stat("Focus", Format.duration(progress.focusMinutes * 60))
        }
        chartBlock("Finished and added") {
          Chart(progress.days) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Finished", day.completed))
              .foregroundStyle(Palette.success)
              .position(by: .value("Kind", "Finished"))
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Added", day.added))
              .foregroundStyle(Palette.dim)
              .position(by: .value("Kind", "Added"))
          }
          .chartXAxis { axis }
          .chartYAxis { yAxis }
        }
        chartBlock("Minutes focused") {
          Chart(progress.days) { day in
            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.focusMinutes))
              .foregroundStyle(Palette.primary)
          }
          .chartXAxis { axis }
          .chartYAxis { yAxis }
        }
        if let best = progress.bestDay {
          Text("Best day: \(best.day.formatted(.dateTime.weekday(.wide).day().month())), \(best.completed) finished")
            .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
      }
      .padding(Metrics.lg)
    }
    .task(id: QueryKey(revision: model.revision, scope: review.period)) { await review.loadProgress() }
    .accessibilityIdentifier("review.progress")
  }

  private var axis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
      AxisGridLine().foregroundStyle(Palette.borderMuted)
      AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        .font(Typeface.numeral).foregroundStyle(Palette.muted)
    }
  }

  private var yAxis: some AxisContent {
    AxisMarks(position: .leading) { _ in
      AxisGridLine().foregroundStyle(Palette.borderMuted)
      AxisValueLabel().font(Typeface.numeral).foregroundStyle(Palette.muted)
    }
  }

  private func chartBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      Text(title).font(Typeface.caption).foregroundStyle(Palette.muted)
      content().frame(height: 180)
    }
    .padding(Metrics.md)
    .cardSurface()
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(Typeface.numeralBody).foregroundStyle(Palette.ink)
      Text(label).font(Typeface.footnote).foregroundStyle(Palette.muted)
    }
  }

  private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}
