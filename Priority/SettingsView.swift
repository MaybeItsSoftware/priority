import AppKit
import PriorityCore
import SwiftUI
// MARK: - Carbon modifier constants (avoid importing Carbon in SwiftUI file)
private let carbonCmdKey = 0x0100
private let carbonShiftKey = 0x0200
private let carbonOptionKey = 0x0800
private let carbonControlKey = 0x1000

// MARK: - Hotkey Recorder

class HotkeyNSTextField: NSTextField {
  var isRecording = false
  var onRecord: ((Int, Int) -> Void)?
  var displayString: String = ""

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func becomeFirstResponder() -> Bool {
    isRecording = true
    stringValue = "Type shortcut\u{2026}"
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    isRecording = false
    stringValue = displayString
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else { return }

    if event.keyCode == 53 {  // Escape = cancel
      window?.makeFirstResponder(nil)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var carbonMods = 0
    if flags.contains(.command) { carbonMods |= carbonCmdKey }
    if flags.contains(.shift) { carbonMods |= carbonShiftKey }
    if flags.contains(.option) { carbonMods |= carbonOptionKey }
    if flags.contains(.control) { carbonMods |= carbonControlKey }

    // Require at least one modifier for a global hotkey
    guard carbonMods != 0 else { return }

    onRecord?(Int(event.keyCode), carbonMods)
    window?.makeFirstResponder(nil)
  }
}

struct HotkeyRecorderField: NSViewRepresentable {
  @Binding var keyCode: Int
  @Binding var modifiers: Int

  func makeNSView(context: Context) -> HotkeyNSTextField {
    let tf = HotkeyNSTextField()
    tf.focusRingType = .none
    tf.isEditable = false
    tf.isSelectable = false
    tf.alignment = .center
    tf.font = .systemFont(ofSize: 12)
    tf.bezelStyle = .roundedBezel
    tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
    tf.stringValue = tf.displayString
    tf.onRecord = { code, mods in
      keyCode = code
      modifiers = mods
    }
    return tf
  }

  func updateNSView(_ tf: HotkeyNSTextField, context: Context) {
    tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
    if !tf.isRecording {
      tf.stringValue = tf.displayString
    }
    tf.onRecord = { code, mods in
      keyCode = code
      modifiers = mods
    }
  }

  static func displayString(keyCode: Int, modifiers: Int) -> String {
    var mods = ""
    if modifiers & carbonControlKey != 0 { mods += "\u{2303}" }
    if modifiers & carbonOptionKey != 0 { mods += "\u{2325}" }
    if modifiers & carbonShiftKey != 0 { mods += "\u{21E7}" }
    if modifiers & carbonCmdKey != 0 { mods += "\u{2318}" }

    let keyNames: [Int: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
      8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
      16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
      23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
      30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
      36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
      43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
      48: "\u{21E5}", 49: "Space", 50: "`", 51: "\u{232B}",
      96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
      103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
      123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    let keyName = keyNames[keyCode] ?? "Key\(keyCode)"
    return mods + keyName
  }
}

// MARK: - Settings View

struct SettingsView: View {
  private struct BuiltInPluginSettingsDescriptor: Identifiable {
    let pluginIdentifier: String
    let displayName: String
    let pluginDescription: String
    let settingsIconSystemName: String
    let plugin: any PluginSettingsPageProviding
    var id: String { pluginIdentifier }

    var shortName: String {
      if displayName.hasPrefix("Native ") {
        return String(displayName.dropFirst("Native ".count))
      }
      return displayName
    }
  }

  private struct PluginCardDescriptor: Identifiable {
    enum Source {
      case builtIn(BuiltInPluginSettingsDescriptor)
      case user(UserPluginManager.InstalledUserPlugin)
    }

    let id: String
    let title: String
    let subtitle: String
    let description: String
    let settingsIconSystemName: String
    let source: Source
  }

  @Environment(AppCoordinator.self) var checkvistManager
  @Environment(SettingsNavState.self) var navState
  @State var selectedPluginCardID: String?
  @State var themeJSONDraft: String = ""
  @State var themeJSONStatusMessage: String = ""
  @State var themeJSONStatusIsError: Bool = false
  @State var isLoadingCheckvistLists = false
  @State var didAutoloadCheckvistLists = false
  @State var mergeSourceListId = ""
  @State var mergeDestinationListId = ""

  var preferences: PreferencesManager {
    checkvistManager.preferences
  }

  func preferenceBinding<T>(_ keyPath: ReferenceWritableKeyPath<PreferencesManager, T>)
    -> Binding<T>
  {
    Binding(
      get: { preferences[keyPath: keyPath] },
      set: { preferences[keyPath: keyPath] = $0 }
    )
  }

  func themeColor(_ token: AppThemeColorToken) -> Color {
    preferences.themeColor(for: token)
  }

  var body: some View {
    paneContent {
      selectedPaneContent
    }
    .tint(preferences.themeAccentColor)
    .task {
      syncSelectedPluginCardIfNeeded()
      if themeJSONDraft.isEmpty {
        themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
      }
      await autoloadCheckvistListsIfNeeded()
    }
    .onChange(of: pluginCardIDs) { _, _ in
      syncSelectedPluginCardIfNeeded()
    }
    .onChange(of: checkvistManager.repository.availableLists.map(\.id)) { _, _ in
      seedMergeSelectionsIfNeeded()
    }
    .onChange(of: checkvistManager.repository.listId) { _, _ in
      if !checkvistManager.repository.listId.isEmpty {
        mergeDestinationListId = checkvistManager.repository.listId
      }
    }
  }

  @ViewBuilder
  private var selectedPaneContent: some View {
    switch navState.selectedPane {
    case .preferences:
      preferencesPane
    case .keybindings:
      keybindingsPane
    case .theme:
      themePane
    case .plugins:
      pluginsPane
    #if DEBUG
      case .debug:
        debugPane
    #endif
    }
  }

  private var builtInPluginSettingsPages: [BuiltInPluginSettingsDescriptor] {
    checkvistManager.activePluginSettingsPages.map {
      BuiltInPluginSettingsDescriptor(
        pluginIdentifier: $0.settingsCardIdentifier,
        displayName: $0.displayName,
        pluginDescription: $0.pluginDescription,
        settingsIconSystemName: $0.settingsIconSystemName,
        plugin: $0
      )
    }
  }

  private var pluginCards: [PluginCardDescriptor] {
    builtInPluginSettingsPages.map { page in
      PluginCardDescriptor(
        id: "builtin:\(page.pluginIdentifier)",
        title: page.shortName,
        subtitle: page.plugin.sidebarStatusLabel(manager: checkvistManager),
        description: page.pluginDescription,
        settingsIconSystemName: page.settingsIconSystemName,
        source: .builtIn(page)
      )
    }
  }

  private var userPluginCards: [PluginCardDescriptor] {
    checkvistManager.userPluginManager.sortedInstalledPlugins.map { plugin in
      let enabled = checkvistManager.userPluginManager.isPluginEnabled(plugin.manifest.id)
      return PluginCardDescriptor(
        id: "user:\(plugin.manifest.id)",
        title: plugin.manifest.name,
        subtitle: enabled ? "Enabled" : "Disabled",
        description: plugin.manifest.summary ?? "User-installed plugin",
        settingsIconSystemName: "puzzlepiece",
        source: .user(plugin)
      )
    }
  }

  private var allPluginCards: [PluginCardDescriptor] { pluginCards + userPluginCards }

  private var pluginCardIDs: [String] {
    allPluginCards.map(\.id)
  }

  private var selectedPluginCard: PluginCardDescriptor? {
    if let selectedPluginCardID,
      let selected = allPluginCards.first(where: { $0.id == selectedPluginCardID })
    {
      return selected
    }
    return pluginCards.first
  }

  private var pluginsPane: some View {
    HStack(spacing: 0) {
      // Sidebar
      List(selection: $selectedPluginCardID) {
        Section("Built-in") {
          ForEach(pluginCards) { card in
            pluginListRow(for: card).tag(card.id as String?)
          }
        }
        if !userPluginCards.isEmpty {
          Section("User Plugins") {
            ForEach(userPluginCards) { card in
              pluginListRow(for: card).tag(card.id as String?)
            }
          }
        }
      }
      .listStyle(.sidebar)
      // A safe-area inset rather than a third element in a VStack: the bar is
      // then laid out *inside* the list's own bounds and the list insets its
      // scroll content to clear it. Stacked, the sidebar's height became the
      // list's ideal height plus the bar, which overflowed the window once
      // there were enough plugins to fill it — and because `paneContent`
      // centres the pane, the overflow clipped the bar off the bottom.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          Divider()
          HStack(spacing: 6) {
            Button {
              checkvistManager.userPluginManager.installPluginPackageInteractively()
            } label: {
              Label("Install Plugin", systemImage: "plus")
            }
            .help("Install a plugin package")
            Button {
              checkvistManager.userPluginManager.openPluginsFolder()
            } label: {
              Label("Open Folder", systemImage: "folder")
            }
            .help("Open the plugins folder in Finder")
          }
          .buttonStyle(.borderless)
          .labelStyle(.iconOnly)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
      }
      .frame(minWidth: 180, idealWidth: 200, maxWidth: 240, maxHeight: .infinity)

      Divider()

      // Detail
      Group {
        if let selectedPluginCard {
          ScrollView {
            switch selectedPluginCard.source {
            case .builtIn:
              Form { pluginSettingsView(for: selectedPluginCard) }
                .formStyle(.grouped)
            case .user(let plugin):
              userPluginDetailView(for: plugin)
            }
          }
        } else {
          ContentUnavailableView(
            "Select a Plugin",
            systemImage: "puzzlepiece.extension",
            description: Text("Choose a plugin from the sidebar to view its settings.")
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func pluginListRow(for card: PluginCardDescriptor) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: card.settingsIconSystemName)
        .frame(width: 18, alignment: .center)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(card.title)
            .lineLimit(1)
          Spacer(minLength: 6)
          Text(card.subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(card.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private func userPluginDetailView(for plugin: UserPluginManager.InstalledUserPlugin) -> some View
  {
    let manager = checkvistManager.userPluginManager
    return Form {
      Section(header: Text(plugin.manifest.name)) {
        if let summary = plugin.manifest.summary, !summary.isEmpty {
          Text(summary)
            .foregroundStyle(.secondary)
        }
        LabeledContent("Version", value: plugin.manifest.version ?? "—")
        LabeledContent("ID", value: plugin.manifest.id)
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { manager.isPluginEnabled(plugin.manifest.id) },
            set: { manager.setPluginEnabled($0, pluginIdentifier: plugin.manifest.id) }
          )
        )
          .toggleStyle(.switch)
      }
      Section {
        Button("Reveal in Finder") {
          manager.revealPluginInFinder(plugin)
        }
        Button("Remove Plugin", role: .destructive) {
          manager.removePlugin(plugin)
        }
      }
    }
    .formStyle(.grouped)
    .id(plugin.id)
  }

  @ViewBuilder
  private func paneContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if navState.selectedPane == .plugins {
      content()
        .padding(.top, 8)
        // Top-aligned, not the default centre: if the pane ever does exceed the
        // window, the overflow should run off one edge where a scroll view can
        // take it, rather than being trimmed off both.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    } else {
      Form {
        content()
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func pluginSettingsView(for card: PluginCardDescriptor) -> some View {
    switch card.source {
    case .builtIn(let page):
      Section(header: Text(card.title)) {
        VStack(alignment: .leading, spacing: 6) {
          Text(page.pluginDescription)
            .foregroundStyle(.secondary)
          Text("Status: \(card.subtitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
      page.plugin.makeSettingsView(manager: checkvistManager)
    case .user:
      EmptyView()
    }
  }

  private func syncSelectedPluginCardIfNeeded() {
    let activeIdentifiers = Set(pluginCardIDs)
    guard !activeIdentifiers.isEmpty else {
      selectedPluginCardID = nil
      return
    }
    if let selectedPluginCardID, activeIdentifiers.contains(selectedPluginCardID) {
      return
    }
    selectedPluginCardID = pluginCards.first?.id
  }
}

struct NamedTimePickerRow: View {
  let label: String
  @Binding var hour: Int

  private let hours = Array(0...23)

  private func hourLabel(_ h: Int) -> String {
    let components = DateComponents(hour: h, minute: 0)
    let date = Calendar.current.date(from: components) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "h a"
    return formatter.string(from: date)
  }

  var body: some View {
    HStack {
      Text(label)
        .frame(width: 80, alignment: .leading)
      Picker("", selection: $hour) {
        ForEach(hours, id: \.self) { h in
          Text(hourLabel(h)).tag(h)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 100)
    }
  }
}
