import SwiftUI

struct ReviewScreen: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Review", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Review")
  }
}
