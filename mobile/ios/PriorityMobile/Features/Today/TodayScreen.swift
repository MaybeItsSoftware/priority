import SwiftUI

struct TodayScreen: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Today", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Today")
  }
}
