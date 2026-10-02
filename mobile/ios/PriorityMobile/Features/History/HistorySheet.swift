import SwiftUI

struct HistorySheet: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "History", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("History")
  }
}
