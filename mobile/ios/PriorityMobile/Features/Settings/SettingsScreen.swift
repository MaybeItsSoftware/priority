import SwiftUI

/// Theme, celebrations, sync, and (in DEBUG) the seeding tools.
struct SettingsScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(ThemeStore.self) private var themes
  @AppStorage(CelebrationStyle.storageKey) private var celebration = CelebrationStyle.default
  @AppStorage(CompletionHaptics.storageKey) private var haptics = true

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Theme", selection: Binding(get: { themes.effectiveIdentifier }, set: { themes.select($0) })) {
            ForEach(themes.available, id: \.identifier) { specification in
              Text(specification.name).tag(specification.identifier)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("settings.theme")
          Picker(
            "Appearance", selection: Binding(get: { themes.effectiveAppearance }, set: { themes.setAppearance($0) })
          ) {
            ForEach(AppearanceChoice.allCases) { choice in
              Text(choice.title).tag(choice)
            }
          }
          .pickerStyle(.segmented)
          .disabled(themes.theme.lockedColorScheme != nil)
          .accessibilityIdentifier("settings.appearance")
        } header: {
          header("Theme")
        }
        .listRowBackground(theme.raised)

        Section {
          Picker("Celebration", selection: $celebration) {
            ForEach(CelebrationStyle.allCases) { style in
              VStack(alignment: .leading, spacing: theme.space.xxs) {
                Text(style.title).font(theme.type.body)
                Text(style.detail).font(theme.type.footnote).foregroundStyle(theme.muted)
              }
              .tag(style)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          CelebrationPreview(style: celebration)
          Toggle("Haptic on complete", isOn: $haptics)
            .toggleStyle(ThemedToggleStyle())
            .font(theme.type.body)
        } header: {
          header("Completing a task")
        }
        .listRowBackground(theme.raised)

        Section {
          NavigationLink {
            SyncSettingsView()
          } label: {
            HStack {
              Label("Sync", systemImage: "arrow.triangle.2.circlepath").font(theme.type.body)
              Spacer()
              SyncStatusLine(compact: true)
            }
          }
          .accessibilityIdentifier("settings.sync")
          // A pairing link opened from outside lands here: say what happened
          // without making anyone dig into the Sync page to find out.
          if let sync = SyncController.shared {
            if sync.isPairing {
              HStack(spacing: theme.space.sm) {
                ProgressView()
                Text("Pairing…").font(theme.type.caption).foregroundStyle(theme.muted)
              }
            } else if let error = sync.pairingError {
              Label(error, systemImage: "exclamationmark.triangle")
                .font(theme.type.caption)
                .foregroundStyle(theme.danger)
                .accessibilityIdentifier("settings.pairingError")
            }
          }
        } header: {
          header("Devices")
        }
        .listRowBackground(theme.raised)

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
        .font(theme.type.body)
        .listRowBackground(theme.raised)
        #endif

        Section {
          LabeledContent("Version", value: Self.version)
            .font(theme.type.body)
        }
        .listRowBackground(theme.raised)
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper)
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
    Text(text).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
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
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  let style: CelebrationStyle
  private static let id = "settings.celebration.preview"

  var body: some View {
    Button {
      guard !model.celebration.isPlaying else { return }
      Task { await model.celebration.play(style, on: Self.id) }
    } label: {
      HStack(spacing: theme.space.sm) {
        TaskCheckbox(status: model.celebration.phase(for: Self.id) == .celebrating ? .completed : .open)
          .celebrationIcon(Self.id)
          .frame(width: 32, height: 40)
        Text("Tap to preview")
          .font(theme.type.body)
          .foregroundStyle(theme.ink)
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
