import Foundation

@MainActor
final class PluginRegistry {
  private(set) var checkvistSyncPluginsByIdentifier: [String: any CheckvistSyncPlugin] = [:]
  private(set) var obsidianPluginsByIdentifier: [String: any ObsidianIntegrationPlugin] = [:]
  private(set) var affinePluginsByIdentifier: [String: any AFFiNEIntegrationPlugin] = [:]
  private(set) var googleCalendarPluginsByIdentifier:
    [String: any GoogleCalendarIntegrationPlugin] =
      [:]
  private(set) var googleTasksPluginsByIdentifier: [String: any GoogleTasksIntegrationPlugin] = [:]
  private(set) var mcpIntegrationPluginsByIdentifier: [String: any MCPIntegrationPlugin] = [:]
  private(set) var dailyLogPluginsByIdentifier: [String: any DailyLogPlugin] = [:]
  private(set) var celebrationPluginsByIdentifier: [String: any CompletionCelebrationPlugin] = [:]
  private(set) var themePluginsByIdentifier: [String: any ThemePlugin] = [:]
  /// Registration order, so the settings picker lists presets the way
  /// `nativeFirst()` writes them rather than in dictionary order.
  private(set) var celebrationPluginOrder: [String] = []
  /// Likewise for themes — the default should be first in the picker because
  /// it is the default, not because one name sorts before the other.
  private(set) var themePluginOrder: [String] = []

  private(set) var activeCheckvistSyncPluginIdentifier: String?
  private(set) var activeObsidianPluginIdentifier: String?
  private(set) var activeAFFiNEPluginIdentifier: String?
  private(set) var activeGoogleCalendarPluginIdentifier: String?
  private(set) var activeGoogleTasksPluginIdentifier: String?
  private(set) var activeMCPIntegrationPluginIdentifier: String?
  private(set) var activeDailyLogPluginIdentifier: String?
  private(set) var activeCelebrationPluginIdentifier: String?
  private(set) var activeThemePluginIdentifier: String?

  var activeCheckvistSyncPlugin: (any CheckvistSyncPlugin)? {
    guard let activeCheckvistSyncPluginIdentifier else { return nil }
    return checkvistSyncPluginsByIdentifier[activeCheckvistSyncPluginIdentifier]
  }

  var activeObsidianPlugin: (any ObsidianIntegrationPlugin)? {
    guard let activeObsidianPluginIdentifier else { return nil }
    return obsidianPluginsByIdentifier[activeObsidianPluginIdentifier]
  }

  var activeAFFiNEPlugin: (any AFFiNEIntegrationPlugin)? {
    guard let activeAFFiNEPluginIdentifier else { return nil }
    return affinePluginsByIdentifier[activeAFFiNEPluginIdentifier]
  }

  var activeGoogleCalendarPlugin: (any GoogleCalendarIntegrationPlugin)? {
    guard let activeGoogleCalendarPluginIdentifier else { return nil }
    return googleCalendarPluginsByIdentifier[activeGoogleCalendarPluginIdentifier]
  }

  var activeGoogleTasksPlugin: (any GoogleTasksIntegrationPlugin)? {
    guard let activeGoogleTasksPluginIdentifier else { return nil }
    return googleTasksPluginsByIdentifier[activeGoogleTasksPluginIdentifier]
  }

  var activeMCPIntegrationPlugin: (any MCPIntegrationPlugin)? {
    guard let activeMCPIntegrationPluginIdentifier else { return nil }
    return mcpIntegrationPluginsByIdentifier[activeMCPIntegrationPluginIdentifier]
  }

  var activeDailyLogPlugin: (any DailyLogPlugin)? {
    guard let activeDailyLogPluginIdentifier else { return nil }
    return dailyLogPluginsByIdentifier[activeDailyLogPluginIdentifier]
  }

  var activeCelebrationPlugin: (any CompletionCelebrationPlugin)? {
    guard let activeCelebrationPluginIdentifier else { return nil }
    return celebrationPluginsByIdentifier[activeCelebrationPluginIdentifier]
  }

  var activeThemePlugin: (any ThemePlugin)? {
    guard let activeThemePluginIdentifier else { return nil }
    return themePluginsByIdentifier[activeThemePluginIdentifier]
  }

  /// Every registered theme, in registration order. The second list-them-all
  /// accessor, for the second capability that is a menu rather than an
  /// integration — see `celebrationPlugins`.
  var themePlugins: [any ThemePlugin] {
    themePluginOrder.compactMap { themePluginsByIdentifier[$0] }
  }

  /// Every registered preset, in registration order.
  ///
  /// The only capability that needs a list-them-all accessor: the others resolve
  /// to a single active plugin, whereas celebrations are presented to the user
  /// as a choice.
  var celebrationPlugins: [any CompletionCelebrationPlugin] {
    celebrationPluginOrder.compactMap { celebrationPluginsByIdentifier[$0] }
  }

  func register(_ plugin: any CheckvistSyncPlugin, activate: Bool = false) {
    checkvistSyncPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeCheckvistSyncPluginIdentifier == nil {
      activeCheckvistSyncPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any ObsidianIntegrationPlugin, activate: Bool = false) {
    obsidianPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeObsidianPluginIdentifier == nil {
      activeObsidianPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any AFFiNEIntegrationPlugin, activate: Bool = false) {
    affinePluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeAFFiNEPluginIdentifier == nil {
      activeAFFiNEPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any GoogleCalendarIntegrationPlugin, activate: Bool = false) {
    googleCalendarPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeGoogleCalendarPluginIdentifier == nil {
      activeGoogleCalendarPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any GoogleTasksIntegrationPlugin, activate: Bool = false) {
    googleTasksPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeGoogleTasksPluginIdentifier == nil {
      activeGoogleTasksPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any MCPIntegrationPlugin, activate: Bool = false) {
    mcpIntegrationPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeMCPIntegrationPluginIdentifier == nil {
      activeMCPIntegrationPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any DailyLogPlugin, activate: Bool = false) {
    dailyLogPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeDailyLogPluginIdentifier == nil {
      activeDailyLogPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any CompletionCelebrationPlugin, activate: Bool = false) {
    if celebrationPluginsByIdentifier[plugin.pluginIdentifier] == nil {
      celebrationPluginOrder.append(plugin.pluginIdentifier)
    }
    celebrationPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeCelebrationPluginIdentifier == nil {
      activeCelebrationPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any ThemePlugin, activate: Bool = false) {
    if themePluginsByIdentifier[plugin.pluginIdentifier] == nil {
      themePluginOrder.append(plugin.pluginIdentifier)
    }
    themePluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeThemePluginIdentifier == nil {
      activeThemePluginIdentifier = plugin.pluginIdentifier
    }
  }

  @discardableResult
  func activateCheckvistSyncPlugin(identifier: String) -> Bool {
    guard checkvistSyncPluginsByIdentifier[identifier] != nil else { return false }
    activeCheckvistSyncPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateObsidianPlugin(identifier: String) -> Bool {
    guard obsidianPluginsByIdentifier[identifier] != nil else { return false }
    activeObsidianPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateAFFiNEPlugin(identifier: String) -> Bool {
    guard affinePluginsByIdentifier[identifier] != nil else { return false }
    activeAFFiNEPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateGoogleCalendarPlugin(identifier: String) -> Bool {
    guard googleCalendarPluginsByIdentifier[identifier] != nil else { return false }
    activeGoogleCalendarPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateGoogleTasksPlugin(identifier: String) -> Bool {
    guard googleTasksPluginsByIdentifier[identifier] != nil else { return false }
    activeGoogleTasksPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateMCPIntegrationPlugin(identifier: String) -> Bool {
    guard mcpIntegrationPluginsByIdentifier[identifier] != nil else { return false }
    activeMCPIntegrationPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateDailyLogPlugin(identifier: String) -> Bool {
    guard dailyLogPluginsByIdentifier[identifier] != nil else { return false }
    activeDailyLogPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateCelebrationPlugin(identifier: String) -> Bool {
    guard celebrationPluginsByIdentifier[identifier] != nil else { return false }
    activeCelebrationPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateThemePlugin(identifier: String) -> Bool {
    guard themePluginsByIdentifier[identifier] != nil else { return false }
    activeThemePluginIdentifier = identifier
    return true
  }

  static func nativeFirst() -> PluginRegistry {
    let registry = PluginRegistry()
    registry.register(NativeCheckvistSyncPlugin(), activate: true)
    registry.register(NativeObsidianIntegrationPlugin(), activate: true)
    registry.register(NativeAFFiNEIntegrationPlugin(), activate: true)
    // One Google sign-in, shared: Calendar and Tasks are two APIs on the same
    // account, and asking the user to authorise twice would be an accident of
    // how the plugins are split rather than anything they care about.
    let googleAccount = GoogleAccount()
    registry.register(NativeGoogleCalendarIntegrationPlugin(account: googleAccount), activate: true)
    registry.register(NativeGoogleTasksIntegrationPlugin(account: googleAccount), activate: true)
    registry.register(NativeMCPIntegrationPlugin(), activate: true)
    registry.register(NativeDailyLogPlugin(), activate: true)
    // Celebrations are a menu, not a single integration: all presets register,
    // and the user's stored pick is applied afterwards by
    // `CompletionCelebrationManager`. Order here is picker order.
    registry.register(NoneCelebrationPlugin())
    registry.register(StrikeCelebrationPlugin(), activate: true)
    registry.register(FoldCelebrationPlugin())
    registry.register(SparkCelebrationPlugin())
    // Themes, likewise a menu. Priority is the default and follows the
    // system. Zed (ChalkThemePlugin) is the Zed look; Zed Dark is the same
    // palette with the appearance fixed, for running the app dark on a light
    // desktop.
    registry.register(PriorityThemePlugin(), activate: true)
    registry.register(ChalkThemePlugin())
    registry.register(ChalkDarkThemePlugin())
    return registry
  }
}
