import ActivityKit
import SwiftUI
import WidgetKit

/// The running focus block on the Lock Screen and the Dynamic Island.
struct FocusLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FocusActivityAttributes.self) { context in
      LockScreenFocusView(state: context.state)
        .activityBackgroundTint(ChalkColors.paper)
        .activitySystemActionForegroundColor(ChalkColors.ink)
        .widgetURL(URL(string: "priority://focus"))
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: state.isPaused ? "pause.circle" : "scope")
            .font(.system(size: 22))
            .foregroundStyle(state.isPaused ? ChalkColors.amber : ChalkColors.azure)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          FocusClock(state: state, size: 22)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(state.taskTitle).font(WidgetType.sans(15, .medium)).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            FocusProgress(state: state)
            Text(state.isPaused ? "Paused" : "Focusing")
              .font(WidgetType.sans(12)).foregroundStyle(.secondary)
          }
        }
      } compactLeading: {
        Image(systemName: state.isPaused ? "pause.fill" : "scope")
          .foregroundStyle(state.isPaused ? ChalkColors.amber : ChalkColors.azure)
      } compactTrailing: {
        FocusClock(state: state, size: 14)
          .frame(maxWidth: 52)
      } minimal: {
        Image(systemName: state.isPaused ? "pause.fill" : "scope")
          .foregroundStyle(state.isPaused ? ChalkColors.amber : ChalkColors.azure)
      }
      .widgetURL(URL(string: "priority://focus"))
      .keylineTint(ChalkColors.azure)
    }
  }
}

/// Counts up from when the block started, and freezes when it is paused.
struct FocusClock: View {
  let state: FocusActivityAttributes.ContentState
  let size: CGFloat

  var body: some View {
    Group {
      if state.isPaused {
        Text(Self.clock(state.elapsedSeconds))
      } else {
        Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
      }
    }
    .font(WidgetType.mono(size, .medium))
    .monospacedDigit()
    .multilineTextAlignment(.trailing)
    .foregroundStyle(state.isPaused ? ChalkColors.amber : ChalkColors.azure)
  }

  static func clock(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let rest = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
  }
}

/// How far through the committed time the block is.
struct FocusProgress: View {
  let state: FocusActivityAttributes.ContentState

  var body: some View {
    if let end = state.plannedEnd, let planned = state.plannedSeconds, planned > 0 {
      if state.isPaused {
        ProgressView(value: min(1, Double(state.elapsedSeconds) / Double(planned)))
          .tint(ChalkColors.amber)
      } else {
        ProgressView(timerInterval: state.timerStart...max(end, state.timerStart.addingTimeInterval(1)), countsDown: false) {
          EmptyView()
        } currentValueLabel: {
          EmptyView()
        }
        .tint(ChalkColors.azure)
      }
    }
  }
}

struct LockScreenFocusView: View {
  let state: FocusActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(state.isPaused ? "Paused" : "Focusing", systemImage: state.isPaused ? "pause.fill" : "scope")
          .font(WidgetType.sans(12))
          .foregroundStyle(state.isPaused ? ChalkColors.amber : ChalkColors.azure)
        Spacer()
        if let planned = state.plannedSeconds {
          Text("of \(WidgetType.duration(planned))").font(WidgetType.mono(12)).foregroundStyle(ChalkColors.muted)
        }
      }
      HStack(alignment: .center) {
        Text(state.taskTitle)
          .font(WidgetType.sans(17, .medium))
          .foregroundStyle(ChalkColors.ink)
          .lineLimit(2)
        Spacer(minLength: 8)
        FocusClock(state: state, size: 26)
          .frame(maxWidth: 110, alignment: .trailing)
      }
      FocusProgress(state: state)
    }
    .padding(16)
  }
}
