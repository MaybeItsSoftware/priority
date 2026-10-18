import SwiftUI
import WidgetKit

/// The watch's complications and its Smart Stack card: the running block
/// with its clock, or what is next and how many are left. They draw the
/// snapshot the watch app last saved; the app reloads them when it changes.
@main
struct TaktWatchWidgets: WidgetBundle {
  var body: some Widget {
    TaktNowWidget()
  }
}

struct NowEntry: TimelineEntry {
  let date: Date
  let snapshot: WatchSnapshot
}

struct NowProvider: TimelineProvider {
  func placeholder(in context: Context) -> NowEntry {
    NowEntry(date: .now, snapshot: .preview)
  }

  func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
    completion(NowEntry(date: .now, snapshot: context.isPreview ? .preview : WatchStorage.load() ?? .empty))
  }

  /// The clock runs on the watch face itself, so a running block needs one
  /// entry, and one more where its plan runs out and the face turns to the
  /// overrun. The app reloads the timeline whenever the phone sends news.
  func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
    let snapshot = WatchStorage.load() ?? .empty
    let now = Date.now
    var entries = [NowEntry(date: now, snapshot: snapshot)]
    if let end = snapshot.session?.plannedEnd, end > now {
      entries.append(NowEntry(date: end, snapshot: snapshot))
    }
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3_600))))
  }
}

struct TaktNowWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchStorage.widgetKind, provider: NowProvider()) { entry in
      NowView(entry: entry)
        .containerBackground(for: .widget) { WatchPalette.page }
    }
    .configurationDisplayName("Takt")
    .description("The running focus block, or what's next today.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
  }
}

struct NowView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NowEntry

  private var session: WatchSnapshot.Session? { entry.snapshot.session }
  private var next: WatchSnapshot.Task? { entry.snapshot.nextUp }
  private var left: Int { entry.snapshot.openTasks.count }
  private var isOver: Bool {
    guard let end = session?.plannedEnd else { return false }
    return entry.date >= end
  }

  var body: some View {
    switch family {
    case .accessoryCircular: circular
    case .accessoryCorner: corner
    case .accessoryInline: inline
    default: rectangular
    }
  }

  // MARK: Circular

  @ViewBuilder private var circular: some View {
    if let session, let end = session.plannedEnd, !isOver {
      ProgressView(timerInterval: session.timerStart...end, countsDown: true) {
        Image(systemName: "timer")
      } currentValueLabel: {
        Image(systemName: "timer").foregroundStyle(WatchPalette.azure)
      }
      .progressViewStyle(.circular)
      .tint(WatchPalette.azure)
      .widgetAccentable()
    } else if let session {
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: session.isPaused ? "pause.fill" : "timer")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(session.isPaused ? WatchPalette.amber : WatchPalette.azure)
          .widgetAccentable()
      }
    } else {
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: 0) {
          Text("\(left)")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .widgetAccentable()
          Text("LEFT").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("\(left) left today")
    }
  }

  // MARK: Corner

  @ViewBuilder private var corner: some View {
    if let session {
      Image(systemName: session.isPaused ? "pause.fill" : "timer")
        .font(.system(size: 20, weight: .bold))
        .widgetAccentable()
        .widgetLabel {
          if session.isPaused {
            Text(WatchFormat.clock(session.elapsedSeconds(at: entry.date)))
          } else {
            Text(timerInterval: session.timerStart...Date.distantFuture, countsDown: false)
          }
        }
    } else {
      Text("\(left)")
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .widgetAccentable()
        .widgetLabel(next?.title ?? "Nothing left")
    }
  }

  // MARK: Inline

  @ViewBuilder private var inline: some View {
    if let session {
      if session.isPaused {
        Text("Paused · \(session.title)")
      } else {
        Text("\(Text(timerInterval: session.timerStart...Date.distantFuture, countsDown: false)) \(session.title)")
      }
    } else if let next {
      Text("\(left) left · \(next.title)")
    } else {
      Text("Nothing left today")
    }
  }

  // MARK: Rectangular — the Smart Stack card too

  @ViewBuilder private var rectangular: some View {
    VStack(alignment: .leading, spacing: 1) {
      if let session {
        Text(session.isPaused ? "PAUSED" : (isOver ? "OVER PLAN" : "FOCUS"))
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(1.2)
          .foregroundStyle(session.isPaused || isOver ? WatchPalette.amber : WatchPalette.azure)
          .widgetAccentable()
        Text(session.title)
          .font(.headline)
          .lineLimit(1)
        Group {
          if session.isPaused {
            Text(WatchFormat.clock(session.elapsedSeconds(at: entry.date)))
          } else if let end = session.plannedEnd, !isOver {
            Text(timerInterval: entry.date...end, countsDown: true)
          } else {
            Text(timerInterval: session.timerStart...Date.distantFuture, countsDown: false)
          }
        }
        .font(.system(.body, design: .monospaced).weight(.semibold))
        .monospacedDigit()
      } else if let next {
        Text("NEXT · \(left) LEFT")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(1.2)
          .foregroundStyle(WatchPalette.azure)
          .widgetAccentable()
        Text(next.title)
          .font(.headline)
          .lineLimit(2)
        if let detail = WatchFormat.detail(next) {
          Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
      } else {
        Text("TODAY")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(1.2)
          .foregroundStyle(WatchPalette.emerald)
          .widgetAccentable()
        Text(entry.snapshot.generatedAt == .distantPast ? "Open Takt on your iPhone" : "Nothing left today")
          .font(.headline)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension WatchSnapshot {
  /// What the face gallery shows before there is anything real.
  static var preview: WatchSnapshot {
    WatchSnapshot(
      tasks: [
        .init(id: "1", title: "Polish the outline rows", detail: "Due today", estimateSeconds: 2_700),
        .init(id: "2", title: "Take screenshots", detail: "Work", estimateSeconds: 1_200),
        .init(id: "3", title: "Stretch", detail: "Daily", isDaily: true),
      ],
      session: nil, generatedAt: .now)
  }
}
