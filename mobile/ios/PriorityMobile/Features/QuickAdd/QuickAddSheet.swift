import SwiftUI

struct QuickAddSheet: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    EmptyState(title: "Add task", message: "Coming soon.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Add task")
  }
}
