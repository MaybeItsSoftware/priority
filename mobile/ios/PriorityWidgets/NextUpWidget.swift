import SwiftUI
import WidgetKit

struct NextUpEntry: TimelineEntry {
  let date: Date
}

struct NextUpProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextUpEntry { NextUpEntry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) { completion(NextUpEntry(date: .now)) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
    completion(Timeline(entries: [NextUpEntry(date: .now)], policy: .never))
  }
}

struct NextUpWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextUp", provider: NextUpProvider()) { _ in
      Text("Priority").containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Next up")
  }
}
