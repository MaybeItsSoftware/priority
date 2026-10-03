import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot
}

/// Reads the snapshot the app wrote. The app reloads the timelines when it
/// writes a new one; a timeline also refreshes at midnight, when "today" moves
/// on whether or not the app has been opened.
struct SnapshotProvider: TimelineProvider {
  func placeholder(in context: Context) -> SnapshotEntry {
    SnapshotEntry(date: .now, snapshot: .sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
    let snapshot = context.isPreview ? (WidgetSnapshot.load() ?? .sample) : (WidgetSnapshot.load() ?? .empty)
    completion(SnapshotEntry(date: .now, snapshot: snapshot))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
    let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .empty)
    let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
      ?? .now.addingTimeInterval(3_600)
    completion(Timeline(entries: [entry], policy: .after(midnight)))
  }
}

/// What to do next, and what is left of today.
struct NextUpWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextUp", provider: SnapshotProvider()) { entry in
      let palette = WidgetPalette.current
      NextUpWidgetView(snapshot: entry.snapshot)
        .environment(\.widgetPalette, palette)
        .containerBackground(palette.paper, for: .widget)
    }
    .configurationDisplayName("Next up")
    .description("The next thing to do, and what's left of today.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
  }
}

/// How many tasks today has a claim on.
struct TodayCountWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TodayCount", provider: SnapshotProvider()) { entry in
      let palette = WidgetPalette.current
      TodayCountView(snapshot: entry.snapshot)
        .environment(\.widgetPalette, palette)
        .containerBackground(palette.paper, for: .widget)
    }
    .configurationDisplayName("Today")
    .description("How many tasks are on today.")
    .supportedFamilies([.accessoryCircular, .systemSmall])
  }
}

struct NextUpWidgetView: View {
  @Environment(\.widgetPalette) private var palette
  @Environment(\.widgetFamily) private var environmentFamily
  let snapshot: WidgetSnapshot
  /// Set by the render tests, which have no widget host to say the size.
  var familyOverride: WidgetFamily?

  private var family: WidgetFamily { familyOverride ?? environmentFamily }

  var body: some View {
    switch family {
    case .accessoryInline:
      Text(snapshot.nextUp.map { "Next: \($0.title)" } ?? "Nothing planned")
        .widgetURL(url)
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        Text("Next up").font(palette.sans(12)).foregroundStyle(palette.muted)
        Text(snapshot.nextUp?.title ?? "Nothing planned").font(palette.sans(14, .medium)).lineLimit(2)
        Text("\(snapshot.todayCount) today").font(palette.mono(11)).foregroundStyle(palette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(url)
    case .systemSmall:
      small
    default:
      list
    }
  }

  private var url: URL {
    snapshot.nextUp.map { URL(string: "priority://task/\($0.id)")! } ?? URL(string: "priority://today")!
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if let running = snapshot.running {
        RunningLine(running: running)
      }
      Spacer(minLength: 0)
      if let next = snapshot.nextUp {
        Text("Next up").font(palette.sans(11)).foregroundStyle(palette.muted)
        Text(next.title)
          .font(palette.sans(15, .medium))
          .foregroundStyle(palette.ink)
          .lineLimit(3)
        if let estimate = next.estimateSeconds {
          Text(WidgetType.duration(estimate)).font(palette.mono(11)).foregroundStyle(palette.muted)
        }
      } else {
        Text("Nothing planned").font(palette.sans(14)).foregroundStyle(palette.muted)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(url)
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.bottom, 6)
      if let running = snapshot.running {
        RunningLine(running: running).padding(.bottom, 6)
      }
      if snapshot.items.isEmpty {
        Spacer()
        Text("Nothing planned for today").font(palette.sans(14)).foregroundStyle(palette.muted)
        Spacer()
      } else {
        ForEach(Array(snapshot.items.prefix(family == .systemLarge ? 6 : 3))) { item in
          Link(destination: URL(string: "priority://task/\(item.id)")!) {
            ItemRow(item: item, isRunning: item.id == snapshot.running?.taskID)
          }
          Rectangle().fill(palette.border).frame(height: palette.hairline)
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(URL(string: "priority://today"))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Today").font(palette.sans(13, .semibold)).foregroundStyle(palette.ink)
      Spacer()
      Text("\(snapshot.todayCount)").font(palette.mono(13, .medium)).foregroundStyle(palette.primary)
      if snapshot.remainingSeconds > 0 {
        Text(WidgetType.duration(snapshot.remainingSeconds) + " left")
          .font(palette.mono(11)).foregroundStyle(palette.muted)
      }
    }
  }
}

private struct ItemRow: View {
  @Environment(\.widgetPalette) private var palette
  let item: WidgetSnapshot.Item
  let isRunning: Bool

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: max(0, palette.controlRadius - 2))
        .strokeBorder(isRunning ? palette.primary : palette.dim, lineWidth: 1.2)
        .frame(width: 14, height: 14)
      VStack(alignment: .leading, spacing: 0) {
        Text(item.title).font(palette.sans(13)).foregroundStyle(palette.ink).lineLimit(1)
        if let detail = [item.reason, item.listName].compactMap({ $0 }).first {
          Text(detail).font(palette.sans(10)).foregroundStyle(reasonColor).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let estimate = item.estimateSeconds {
        Text(WidgetType.duration(estimate)).font(palette.mono(11)).foregroundStyle(palette.muted)
      }
    }
    .padding(.vertical, 5)
  }

  private var reasonColor: Color {
    switch item.reason {
    case "Overdue": palette.danger
    case "Running": palette.primary
    default: palette.muted
    }
  }
}

/// The running block, with a timer the system keeps live.
struct RunningLine: View {
  @Environment(\.widgetPalette) private var palette
  let running: WidgetSnapshot.Running

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: running.isPaused ? "pause.fill" : "scope")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(running.isPaused ? palette.warning : palette.primary)
      Text(running.title).font(palette.sans(12, .medium)).foregroundStyle(palette.ink).lineLimit(1)
      Spacer(minLength: 4)
      if running.isPaused {
        Text(WidgetType.duration(running.elapsedSeconds)).font(palette.mono(11)).foregroundStyle(palette.muted)
      } else {
        Text(timerInterval: running.timerStart...Date.distantFuture, countsDown: false)
          .font(palette.mono(11)).foregroundStyle(palette.primary)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 56, alignment: .trailing)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(palette.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: palette.controlRadius))
    .overlay(
      RoundedRectangle(cornerRadius: palette.controlRadius)
        .strokeBorder(palette.primary.opacity(0.4), lineWidth: palette.hairline))
  }
}

struct TodayCountView: View {
  @Environment(\.widgetPalette) private var palette
  @Environment(\.widgetFamily) private var family
  let snapshot: WidgetSnapshot

  var body: some View {
    Group {
      if family == .accessoryCircular {
        ZStack {
          AccessoryWidgetBackground()
          VStack(spacing: 0) {
            Text("\(snapshot.todayCount)").font(palette.mono(20, .medium))
            Text("today").font(palette.sans(9))
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text("Today").font(palette.sans(13, .semibold)).foregroundStyle(palette.ink)
          Spacer()
          Text("\(snapshot.todayCount)").font(palette.mono(44, .medium)).foregroundStyle(palette.ink)
          Text(snapshot.todayCount == 1 ? "task on today" : "tasks on today")
            .font(palette.sans(12)).foregroundStyle(palette.muted)
          Text("\(snapshot.completedToday) done · \(WidgetType.duration(snapshot.loggedTodaySeconds)) logged")
            .font(palette.mono(11)).foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .widgetURL(URL(string: "priority://today"))
  }
}

#Preview(as: .systemMedium) {
  NextUpWidget()
} timeline: {
  SnapshotEntry(date: .now, snapshot: .sample)
}
