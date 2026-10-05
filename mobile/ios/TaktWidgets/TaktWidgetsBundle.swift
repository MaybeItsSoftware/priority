import SwiftUI
import WidgetKit

@main
struct TaktWidgetsBundle: WidgetBundle {
  var body: some Widget {
    NextUpWidget()
    TodayCountWidget()
    FocusLiveActivity()
    QuickAddControl()
  }
}
