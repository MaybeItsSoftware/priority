import SwiftUI

struct SettingsScreen: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Settings", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Settings")
  }
}
