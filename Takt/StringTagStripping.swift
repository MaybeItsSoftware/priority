import Foundation

extension String {
  /// The content string with inline `#tag` and `@tag` markers removed, for
  /// places that show a task's text to be read rather than edited.
  ///
  /// Lived at the bottom of `KanbanBoardView` until that view was removed with
  /// the rest of the legacy popover surface. It is a string helper, and never
  /// belonged to a view.
  var strippingTags: String {
    let pattern = try? NSRegularExpression(pattern: "\\s*[#@][\\w-]+")
    let range = NSRange(startIndex..., in: self)
    return pattern?.stringByReplacingMatches(in: self, range: range, withTemplate: "") ?? self
  }
}
