import SwiftUI

struct FocusScreen: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Focus", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Focus")
  }
}
