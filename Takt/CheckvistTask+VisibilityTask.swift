import Foundation
import TaktCore

/// Ties the app's task model to the abstraction the visibility and filter
/// algorithms are written against.
///
/// Deliberately app-side rather than next to `CheckvistTask`: `TaktCore`
/// declares `VisibilityTask` and must not learn about Checkvist, and
/// `TaktPlugins` — which compiles `CheckvistModels.swift` — must not learn
/// about `TaktCore`. This one line is the only place the two meet, and
/// `CheckvistTask` already satisfies every requirement, so there is nothing to
/// implement.
extension CheckvistTask: VisibilityTask {}
