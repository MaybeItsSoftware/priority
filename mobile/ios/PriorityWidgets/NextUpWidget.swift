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
      NextUpWidgetView(snapshot: entry.snapshot)
        .containerBackground(ChalkColors.paper, for: .widget)
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
      TodayCountView(snapshot: entry.snapshot)
        .containerBackground(ChalkColors.paper, for: .widget)
    }
    .configurationDisplayName("Today")
    .description("How many tasks are on today.")
    .supportedFamilies([.accessoryCircular, .systemSmall])
  }
}

struct NextUpWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let snapshot: WidgetSnapshot

  var body: some View {
    switch family {
    case .accessoryInline:
      Text(snapshot.nextUp.map { "Next: \($0.title)" } ?? "Nothing planned")
        .widgetURL(url)
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        Text("Next up").font(WidgetType.sans(12)).foregroundStyle(.secondary)
        Text(snapshot.nextUp?.title ?? "Nothing planned").font(WidgetType.sans(14, .medium)).lineLimit(2)
        Text("\(snapshot.todayCount) today").font(WidgetType.mono(11)).foregroundStyle(.secondary)
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
        Text("Next up").font(WidgetType.sans(11)).foregroundStyle(ChalkColors.muted)
        Text(next.title)
          .font(WidgetType.sans(15, .medium))
          .foregroundStyle(ChalkColors.ink)
          .lineLimit(3)
        if let estimate = next.estimateSeconds {
          Text(WidgetType.duration(estimate)).font(WidgetType.mono(11)).foregroundStyle(ChalkColors.muted)
        }
      } else {
        Text("Nothing planned").font(WidgetType.sans(14)).foregroundStyle(ChalkColors.muted)
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
        Text("Nothing planned for today").font(WidgetType.sans(14)).foregroundStyle(ChalkColors.muted)
        Spacer()
      } else {
        ForEach(Array(snapshot.items.prefix(family == .systemLarge ? 6 : 3))) { item in
          Link(destination: URL(string: "priority://task/\(item.id)")!) {
            ItemRow(item: item, isRunning: item.id == snapshot.running?.taskID)
          }
          Rectangle().fill(ChalkColors.border).frame(height: 1)
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(URL(string: "priority://today"))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Today").font(WidgetType.sans(13, .semibold)).foregroundStyle(ChalkColors.ink)
      Spacer()
      Text("\(snapshot.todayCount)").font(WidgetType.mono(13, .medium)).foregroundStyle(ChalkColors.azure)
      if snapshot.remainingSeconds > 0 {
        Text(WidgetType.duration(snapshot.remainingSeconds) + " left")
          .font(WidgetType.mono(11)).foregroundStyle(ChalkColors.muted)
      }
    }
  }
}

private struct ItemRow: View {
  let item: WidgetSnapshot.Item
  let isRunning: Bool

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(isRunning ? ChalkColors.azure : ChalkColors.dim, lineWidth: 1.2)
        .frame(width: 14, height: 14)
      VStack(alignment: .leading, spacing: 0) {
        Text(item.title).font(WidgetType.sans(13)).foregroundStyle(ChalkColors.ink).lineLimit(1)
        if let detail = [item.reason, item.listName].compactMap({ $0 }).first {
          Text(detail).font(WidgetType.sans(10)).foregroundStyle(reasonColor).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let estimate = item.estimateSeconds {
        Text(WidgetType.duration(estimate)).font(WidgetType.mono(11)).foregroundStyle(ChalkColors.muted)
      }
    }
    .padding(.vertical, 5)
  }

  private var reasonColor: Color {
    switch item.reason {
    case "Overdue": ChalkColors.raspberry
    case "Running": ChalkColors.azure
    default: ChalkColors.muted
    }
  }
}

/// The running block, with a timer the system keeps live.
struct RunningLine: View {
  let running: WidgetSnapshot.Running

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: running.isPaused ? "pause.fill" : "scope")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(running.isPaused ? ChalkColors.amber : ChalkColors.azure)
      Text(running.title).font(WidgetType.sans(12, .medium)).foregroundStyle(ChalkColors.ink).lineLimit(1)
      Spacer(minLength: 4)
      if running.isPaused {
        Text(WidgetType.duration(running.elapsedSeconds)).font(WidgetType.mono(11)).foregroundStyle(ChalkColors.muted)
      } else {
        Text(timerInterval: running.timerStart...Date.distantFuture, countsDown: false)
          .font(WidgetType.mono(11)).foregroundStyle(ChalkColors.azure)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 56, alignment: .trailing)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(ChalkColors.azure.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ChalkColors.azure.opacity(0.4), lineWidth: 1))
  }
}

struct TodayCountView: View {
  @Environment(\.widgetFamily) private var family
  let snapshot: WidgetSnapshot

  var body: some View {
    Group {
      if family == .accessoryCircular {
        ZStack {
          AccessoryWidgetBackground()
          VStack(spacing: 0) {
            Text("\(snapshot.todayCount)").font(WidgetType.mono(20, .medium))
            Text("today").font(WidgetType.sans(9))
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text("Today").font(WidgetType.sans(13, .semibold)).foregroundStyle(ChalkColors.ink)
          Spacer()
          Text("\(snapshot.todayCount)").font(WidgetType.mono(44, .medium)).foregroundStyle(ChalkColors.ink)
          Text(snapshot.todayCount == 1 ? "task on today" : "tasks on today")
            .font(WidgetType.sans(12)).foregroundStyle(ChalkColors.muted)
          Text("\(snapshot.completedToday) done · \(WidgetType.duration(snapshot.loggedTodaySeconds)) logged")
            .font(WidgetType.mono(11)).foregroundStyle(ChalkColors.muted)
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
