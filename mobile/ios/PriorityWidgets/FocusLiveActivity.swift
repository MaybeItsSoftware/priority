import ActivityKit
import SwiftUI
import WidgetKit

/// The running focus block on the Lock Screen and the Dynamic Island.
struct FocusLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FocusActivityAttributes.self) { context in
      let palette = WidgetPalette.current
      LockScreenFocusView(state: context.state)
        .environment(\.widgetPalette, palette)
        .activityBackgroundTint(palette.paper)
        .activitySystemActionForegroundColor(palette.ink)
        .widgetURL(URL(string: "priority://focus"))
    } dynamicIsland: { context in
      let state = context.state
      let palette = WidgetPalette.current
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: state.isPaused ? "pause.circle" : "scope")
            .font(.system(size: 22))
            .foregroundStyle(state.isPaused ? palette.warning : palette.primary)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          FocusClock(state: state, size: 22).environment(\.widgetPalette, palette)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(state.taskTitle).font(palette.sans(15, .medium)).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            FocusProgress(state: state).environment(\.widgetPalette, palette)
            Text(state.isPaused ? "Paused" : "Focusing")
              .font(palette.sans(12)).foregroundStyle(palette.muted)
          }
        }
      } compactLeading: {
        Image(systemName: state.isPaused ? "pause.fill" : "scope")
          .foregroundStyle(state.isPaused ? palette.warning : palette.primary)
      } compactTrailing: {
        FocusClock(state: state, size: 14).environment(\.widgetPalette, palette)
          .frame(maxWidth: 52)
      } minimal: {
        Image(systemName: state.isPaused ? "pause.fill" : "scope")
          .foregroundStyle(state.isPaused ? palette.warning : palette.primary)
      }
      .widgetURL(URL(string: "priority://focus"))
      .keylineTint(palette.primary)
    }
  }
}

/// Counts up from when the block started, and freezes when it is paused.
struct FocusClock: View {
  @Environment(\.widgetPalette) private var palette
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
    .font(palette.mono(size, .medium))
    .monospacedDigit()
    .multilineTextAlignment(.trailing)
    .foregroundStyle(state.isPaused ? palette.warning : palette.primary)
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
  @Environment(\.widgetPalette) private var palette
  let state: FocusActivityAttributes.ContentState

  var body: some View {
    if let end = state.plannedEnd, let planned = state.plannedSeconds, planned > 0 {
      if state.isPaused {
        ProgressView(value: min(1, Double(state.elapsedSeconds) / Double(planned)))
          .tint(palette.warning)
      } else {
        ProgressView(timerInterval: state.timerStart...max(end, state.timerStart.addingTimeInterval(1)), countsDown: false) {
          EmptyView()
        } currentValueLabel: {
          EmptyView()
        }
        .tint(palette.primary)
      }
    }
  }
}

struct LockScreenFocusView: View {
  @Environment(\.widgetPalette) private var palette
  let state: FocusActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(state.isPaused ? "Paused" : "Focusing", systemImage: state.isPaused ? "pause.fill" : "scope")
          .font(palette.sans(12))
          .foregroundStyle(state.isPaused ? palette.warning : palette.primary)
        Spacer()
        if let planned = state.plannedSeconds {
          Text("of \(WidgetType.duration(planned))").font(palette.mono(12)).foregroundStyle(palette.muted)
        }
      }
      HStack(alignment: .center) {
        Text(state.taskTitle)
          .font(palette.sans(17, .medium))
          .foregroundStyle(palette.ink)
          .lineLimit(2)
        Spacer(minLength: 8)
        FocusClock(state: state, size: 26)
          .frame(maxWidth: 110, alignment: .trailing)
      }
      FocusProgress(state: state).environment(\.widgetPalette, palette)
    }
    .padding(16)
  }
}
