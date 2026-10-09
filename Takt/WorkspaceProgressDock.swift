import Charts
import TaktCore
import SwiftUI

/// The bottom dock: task progress over a period, plotted a day at a time.
///
/// Bars are what was closed each day, and the line what was added, so the one
/// question the graph is for — is the work going down or piling up — is the
/// gap between them. The totals in the header say the same in numbers. It is
/// Zed's bottom dock in position (under the main pane, ⌘J) and holds no
/// keyboard of its own: there is nothing in it to type into or step through.
struct WorkspaceProgressDock: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var series = TaskProgressSeries(days: [])
  @State private var hoveredDay: Date?

  var body: some View {
    VStack(spacing: 0) {
      header
      chart
        .padding(.horizontal, theme.space.sm)
        .padding(.vertical, theme.space.xs)
    }
    .background(theme.paper)
    .background { WorkspaceProgressReloader(series: $series) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Progress")
  }

  private var header: some View {
    HStack(spacing: theme.space.sm) {
      Text("Progress")
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
      summary
      Spacer(minLength: theme.space.sm)
      HStack(spacing: 0) {
        ForEach(TaskProgressPeriod.allCases) { period in
          Button(period.shortTitle) { model.progressPeriod = period }
            .buttonStyle(WorkspacePaneIconButtonStyle(isOn: model.progressPeriod == period))
            .font(theme.monoCaptionFont)
            .accessibilityLabel("Last \(period.days) days")
        }
      }
      WorkspacePaneIconButton("xmark", title: "Hide progress", command: .windowToggleProgressDock) {
        model.isBottomDockVisible = false
      }
    }
    .padding(.horizontal, theme.space.sm)
    .frame(height: theme.paneIconButtonSize + theme.space.xs)
    .overlay(alignment: .bottom) { FocusRule() }
  }

  /// Done, added and the difference, or the hovered day's own figures.
  private var summary: some View {
    let hovered = hoveredDay.flatMap { day in series.days.first { $0.dayStart == day } }
    return HStack(spacing: theme.space.sm) {
      if let hovered {
        Text(hovered.dayStart, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
          .foregroundStyle(theme.ink)
        legendFigure(hovered.completed, "done", colour: theme.success)
        legendFigure(hovered.added, "added", colour: theme.primary)
      } else {
        legendFigure(series.totalCompleted, "done", colour: theme.success)
        legendFigure(series.totalAdded, "added", colour: theme.primary)
        Text(series.net >= 0 ? "net +\(series.net)" : "net −\(-series.net)")
          .foregroundStyle(series.net >= 0 ? theme.success : theme.muted)
      }
    }
    .font(theme.monoCaptionFont)
    .monospacedDigit()
  }

  private func legendFigure(_ value: Int, _ label: String, colour: Color) -> some View {
    HStack(spacing: theme.space.xxs) {
      Rectangle().fill(colour).frame(width: theme.space.xs, height: theme.space.xs)
      Text("\(value) \(label)").foregroundStyle(theme.muted)
    }
  }

  private var chart: some View {
    Chart {
      ForEach(series.days) { day in
        BarMark(
          x: .value("Day", day.dayStart, unit: .day),
          y: .value("Done", day.completed))
          .foregroundStyle(theme.success.opacity(hoveredDay == nil || hoveredDay == day.dayStart ? 1 : 0.4))
      }
      ForEach(series.days) { day in
        LineMark(
          x: .value("Day", day.dayStart, unit: .day),
          y: .value("Added", day.added),
          series: .value("Series", "Added"))
          .foregroundStyle(theme.primary)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
          .interpolationMethod(.monotone)
      }
      if let hoveredDay {
        RuleMark(x: .value("Day", hoveredDay, unit: .day))
          .foregroundStyle(theme.border)
          .lineStyle(StrokeStyle(lineWidth: theme.hairline))
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: axisStride)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: theme.hairline)).foregroundStyle(theme.borderMuted)
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: theme.hairline)).foregroundStyle(theme.borderMuted)
        AxisValueLabel()
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              guard let frame = proxy.plotFrame else { return }
              let x = location.x - geometry[frame].origin.x
              let date: Date? = proxy.value(atX: x)
              hoveredDay = date.map { Calendar.current.startOfDay(for: $0) }
            case .ended:
              hoveredDay = nil
            }
          }
      }
    }
    .accessibilityLabel(
      "\(series.totalCompleted) tasks done and \(series.totalAdded) added in the last \(model.progressPeriod.days) days")
  }

  /// Days between x-axis labels: about seven labels whatever the period.
  private var axisStride: Int {
    max(1, model.progressPeriod.days / 7)
  }
}

/// The bottom dock's top edge: a hairline that drags the dock taller or
/// shorter, the vertical twin of `WorkspaceResizeHandle`.
struct WorkspaceHeightHandle: View {
  @Environment(\.theme) private var theme
  @Binding var height: CGFloat
  let range: ClosedRange<CGFloat>
  @State private var dragStartHeight: CGFloat?

  var body: some View {
    Rectangle()
      .fill(theme.border)
      .frame(height: theme.hairline)
      .overlay(
        Rectangle()
          .fill(Color.clear)
          .frame(height: theme.space.sm + theme.hairline)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { value in
                let base = dragStartHeight ?? height
                if dragStartHeight == nil { dragStartHeight = base }
                height = min(max(base - value.translation.height, range.lowerBound), range.upperBound)
              }
              .onEnded { _ in dragStartHeight = nil }
          )
      )
  }
}

/// Reads the dock's series, in a leaf of its own so the refresh counter it
/// watches redraws nothing but this.
///
/// The dock is only mounted while it is showing, so a hidden dock queries
/// nothing. Showing it, or changing the period, reads at once; a refresh
/// waits for the writes around it to settle, because `.task(id:)` cancels the
/// wait when the next one lands, and a burst of edits is then one read.
private struct WorkspaceProgressReloader: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Binding var series: TaskProgressSeries
  /// The period `series` was read for; nil until the first read.
  @State private var loadedPeriod: TaskProgressPeriod?

  /// How long a refresh waits for more writes before reading the series.
  private static let refreshDebounce = Duration.milliseconds(600)

  /// Reloads when the period changes or any task does.
  private struct ReloadKey: Equatable {
    let period: TaskProgressPeriod
    let revision: Int
  }

  var body: some View {
    Color.clear
      .task(id: ReloadKey(period: model.progressPeriod, revision: model.taskContentRevision)) {
        if loadedPeriod == model.progressPeriod {
          try? await Task.sleep(for: Self.refreshDebounce)
          guard !Task.isCancelled else { return }
        }
        series = model.loadProgressSeries()
        loadedPeriod = model.progressPeriod
      }
  }
}
