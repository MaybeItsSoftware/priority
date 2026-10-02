import SwiftUI

struct SearchScreen: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Search", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Search")
  }
}
