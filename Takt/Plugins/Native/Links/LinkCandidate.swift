import Foundation

/// Something the link picker can offer: a note or folder in an Obsidian
/// vault, or a file or folder in Google Drive. What linking it stores is
/// `url`, named `title` with the type `mimeType` (docs/links.md).
struct LinkCandidate: Identifiable, Hashable, Sendable {
  enum Source: String, Sendable, CaseIterable {
    case obsidian
    case drive
  }

  var id: String { url }
  let url: String
  let title: String
  /// Where it is: the vault and folder, or the Drive file's type.
  let subtitle: String
  let mimeType: String?
  let isFolder: Bool
  let source: Source
  /// The text matched against what is typed: a vault-relative path, a Drive
  /// file's name.
  let searchText: String
}

/// An Obsidian vault on this Mac: its name (what `obsidian://` URLs say) and
/// its folder.
struct ObsidianVault: Hashable, Sendable {
  let name: String
  let url: URL

  init(url: URL) {
    self.url = url.standardizedFileURL
    self.name = url.lastPathComponent
  }
}
