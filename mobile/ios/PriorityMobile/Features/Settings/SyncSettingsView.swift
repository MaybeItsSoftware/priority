import SwiftUI

/// Pairing with the sync server.
struct SyncSettingsView: View {
  var body: some View {
    EmptyState(title: "Sync", message: "Not available yet.", systemImage: "arrow.triangle.2.circlepath")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("Sync")
  }
}
