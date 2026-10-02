import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center (and Lock Screen, and Action button) control that opens
/// Priority on its quick-add sheet.
struct QuickAddControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "uk.co.maybeitsadam.priority.ios.quickadd") {
      ControlWidgetButton(action: OpenQuickAddIntent()) {
        Label("Add task", systemImage: "plus.square")
      }
    }
    .displayName("Add task")
    .description("Opens Priority ready to capture a task.")
  }
}
