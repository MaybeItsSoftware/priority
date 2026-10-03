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
          CelebrationPreview(style: celebration)
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
          // A pairing link opened from outside lands here: say what happened
          // without making anyone dig into the Sync page to find out.
          if let sync = SyncController.shared {
            if sync.isPairing {
              HStack(spacing: Metrics.sm) {
                ProgressView()
                Text("Pairing…").font(Typeface.caption).foregroundStyle(Palette.muted)
              }
            } else if let error = sync.pairingError {
              Label(error, systemImage: "exclamationmark.triangle")
                .font(Typeface.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("settings.pairingError")
            }
          }
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
      .navigationDestination(isPresented: Binding(
        get: { model.navigation.isSyncSettingsPresented },
        set: { model.navigation.isSyncSettingsPresented = $0 })) { SyncSettingsView() }
      .navigationTitle("Settings")
      .onDisappear { model.navigation.isSyncSettingsPresented = false }
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

/// A sample row that plays the chosen celebration when tapped, so a style
/// can be judged before a real task is spent on it. Plays even with Reduce
/// Motion on — shortened, as it would be for real.
private struct CelebrationPreview: View {
  @Environment(WorkspaceModel.self) private var model
  let style: CelebrationStyle
  private static let id = "settings.celebration.preview"

  var body: some View {
    Button {
      guard !model.celebration.isPlaying else { return }
      Task { await model.celebration.play(style, on: Self.id) }
    } label: {
      HStack(spacing: Metrics.sm) {
        TaskCheckbox(status: model.celebration.phase(for: Self.id) == .celebrating ? .completed : .open)
          .celebrationIcon(Self.id)
          .frame(width: 32, height: 40)
        Text("Tap to preview")
          .font(Typeface.body)
          .foregroundStyle(Palette.ink)
          .celebrationStrike(Self.id)
        Spacer(minLength: 0)
      }
      .celebrationRow(Self.id)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(style == .none)
    .accessibilityIdentifier("settings.celebrationPreview")
  }
}
