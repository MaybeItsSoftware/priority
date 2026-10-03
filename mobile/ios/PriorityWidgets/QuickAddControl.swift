import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center (and Lock Screen, and Action button) control that opens
/// Takt on its quick-add sheet.
struct QuickAddControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "uk.co.maybeitssoftware.takt.quickadd") {
      ControlWidgetButton(action: OpenQuickAddIntent()) {
        Label("Add task", systemImage: "plus.square")
      }
    }
    .displayName("Add task")
    .description("Opens Takt ready to capture a task.")
  }
}
