import Foundation

/// What runs once the workspace is open, outside any screen: the widget
/// bridge, the Live Activity. One line per feature.
@MainActor
let featureInstallers: [(WorkspaceModel) -> Void] = []
