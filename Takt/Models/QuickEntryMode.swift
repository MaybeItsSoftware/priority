import Foundation

enum QuickEntryMode: Equatable {
  case search
  case addSibling
  /// Same field, opposite side of the selection. Separate from `addSibling`
  /// rather than a flag on it because the placeholder has to say which way it
  /// is going — a composer that inserts above but reads "Add task" is a
  /// composer you will use wrongly once and then distrust.
  case addSiblingAbove
  case addChild
  case editTask
  case command
  /// The `dd` sequence opens a mouse- and keyboard-navigable calendar rather
  /// than making the user finish a textual `due …` command.
  case dueDatePicker
  case quickAddDefault
  case quickAddSpecific
}
