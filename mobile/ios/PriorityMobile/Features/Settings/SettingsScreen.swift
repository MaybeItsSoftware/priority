import SwiftUI

/// Theme, celebrations, sync, and (in DEBUG) the seeding tools.
struct SettingsScreen: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system
  @AppStorage(CelebrationStyle.storageKey) private var celebration = CelebrationStyle.default
  @AppStorage(CompletionHaptics.storageKey) private var haptics = true

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Theme", selection: $appearance) {
            ForEach(AppearanceChoice.allCases) { choice in
              Text(choice.title).tag(choice)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("settings.theme")
        } header: {
          header("Theme")
        }
        .listRowBackground(Palette.raised)

        Section {
          Picker("Celebration", selection: $celebration) {
            ForEach(CelebrationStyle.allCases) { style in
              VStack(alignment: .leading, spacing: 2) {
                Text(style.title).font(Typeface.body)
                Text(style.detail).font(Typeface.footnote).foregroundStyle(Palette.muted)
              }
              .tag(style)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          Toggle("Haptic on complete", isOn: $haptics)
            .toggleStyle(ThemedToggleStyle())
            .font(Typeface.body)
        } header: {
          header("Completing a task")
        }
        .listRowBackground(Palette.raised)

        Section {
          NavigationLink {
            SyncSettingsView()
          } label: {
            HStack {
              Label("Sync", systemImage: "arrow.triangle.2.circlepath").font(Typeface.body)
              Spacer()
              SyncStatusLine(compact: true)
            }
          }
          .accessibilityIdentifier("settings.sync")
        } header: {
          header("Devices")
        }
        .listRowBackground(Palette.raised)

        #if DEBUG
        Section {
          Button("Seed 5,000 tasks") {
            model.seedTasks()
            dismiss()
          }
          Button("Seed demo workspace") {
            model.seedDemo()
            dismiss()
          }
        } header: {
          header("Debug")
        }
        .font(Typeface.body)
        .listRowBackground(Palette.raised)
        #endif

        Section {
          LabeledContent("Version", value: Self.version)
            .font(Typeface.body)
        }
        .listRowBackground(Palette.raised)
      }
      .scrollContentBackground(.hidden)
      .background(Palette.paper)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
        }
      }
    }
  }

  private func header(_ text: String) -> some View {
    Text(text).font(Typeface.caption).foregroundStyle(Palette.muted).textCase(nil)
  }

  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}
