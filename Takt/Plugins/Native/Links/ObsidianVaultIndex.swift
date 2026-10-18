import Foundation
import TaktRustCore

/// Finds the Obsidian vaults on this Mac and lists what is in them, for the
/// link picker. Nothing here reads a note's contents: a note is its path.
enum ObsidianVaultIndex {
  /// The most entries one vault contributes. A vault larger than this is
  /// listed in walk order up to it; the picker still finds anything pasted.
  static let entryLimit = 20_000

  /// Obsidian's own list of vaults, `~/Library/Application Support/obsidian/obsidian.json`.
  static var obsidianConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
  }

  /// The vaults Obsidian knows, then the vault around each of `hints` (the
  /// daily log's notes folder, say), then `extra`, each once.
  static func discover(hints: [URL], extra: [URL], configURL: URL = obsidianConfigURL) -> [ObsidianVault] {
    var seen = Set<String>()
    var vaults: [ObsidianVault] = []
    func add(_ url: URL) {
      let vault = ObsidianVault(url: url)
      guard FileManager.default.fileExists(atPath: vault.url.path), seen.insert(vault.url.path).inserted else { return }
      vaults.append(vault)
    }
    configuredVaults(at: configURL).forEach(add)
    hints.compactMap(vaultRoot(containing:)).forEach(add)
    extra.forEach(add)
    return vaults
  }

  /// The vault paths in Obsidian's `obsidian.json`, in the order it lists them.
  static func configuredVaults(at url: URL) -> [URL] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let vaults = object["vaults"] as? [String: Any]
    else { return [] }
    return vaults.values
      .compactMap { ($0 as? [String: Any])?["path"] as? String }
      .sorted()
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  /// The nearest folder at or above `url` holding an `.obsidian` folder.
  static func vaultRoot(containing url: URL) -> URL? {
    var candidate = url.standardizedFileURL
    while candidate.path != "/" {
      var isDirectory: ObjCBool = false
      let marker = candidate.appendingPathComponent(".obsidian").path
      if FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory), isDirectory.boolValue {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    return nil
  }

  /// Every note (`.md`, `.canvas`) and folder in `vault`, dot-folders
  /// skipped, as picker rows.
  static func entries(in vault: ObsidianVault) -> [LinkCandidate] {
    guard
      let walker = FileManager.default.enumerator(
        at: vault.url, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    let rootPath = vault.url.path.hasSuffix("/") ? vault.url.path : vault.url.path + "/"
    var entries: [LinkCandidate] = []
    for case let file as URL in walker {
      guard entries.count < entryLimit else { break }
      let isFolder = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      let ext = file.pathExtension.lowercased()
      guard isFolder || ext == "md" || ext == "canvas" else { continue }
      let path = file.standardizedFileURL.path
      guard path.hasPrefix(rootPath) else { continue }
      let relative = String(path.dropFirst(rootPath.count))
      entries.append(candidate(vault: vault.name, path: relative, isFolder: isFolder))
    }
    return entries
  }

  static func candidate(vault: String, path: String, isFolder: Bool) -> LinkCandidate {
    let url = obsidianLinkUrl(vault: vault, path: path, isFolder: isFolder)
    let described = linkDescribe(url: url, title: nil, mimeType: nil)
    return LinkCandidate(
      url: url, title: described.title, subtitle: described.subtitle, mimeType: nil, isFolder: isFolder,
      source: .obsidian, searchText: isFolder ? path : (path as NSString).deletingPathExtension)
  }
}
