import CryptoKit
import Foundation

/// Reconciles a folder of theme files with the synced `themes` table. This is
/// the decision only: `UserThemeLibrary` on the Mac carries it out.
///
/// Which side changed is decided against the digest of the text last
/// mirrored for each identifier, which the caller keeps between runs:
///
/// - A file and its row hold the same text: nothing to do.
/// - The file still holds what was last mirrored, and the row does not: the
///   row was edited on another device, so it is written into the file.
/// - Otherwise the file was edited here, and its text goes into the row.
/// - A row with no file that was mirrored before: the file was removed here,
///   so the row is deleted. A row that was never mirrored came from another
///   device, and is written into the folder.
/// - A file that was mirrored before, whose row has gone: it was removed on
///   another device, so the file is removed. If the file has been edited here
///   since, the edit wins and the row comes back.
///
/// Nothing is written that would not change anything. A file written from a
/// row reads back equal to it, so it is not sent again. While any file in the
/// folder cannot be read, nothing is deleted or written: a file half way
/// through an edit does not say which theme it is.
public enum ThemeFolderMirror {
  public enum Action: Equatable, Sendable {
    /// The theme each action is about, so a caller whose action failed can
    /// put that theme's digest back the way it was.
    public var identifier: String {
      switch self {
      case .upsertRow(let identifier, _), .deleteRow(let identifier),
        .writeFile(let identifier, _, _), .removeFile(let identifier, _):
        return identifier
      }
    }

    case upsertRow(identifier: String, json: String)
    case deleteRow(identifier: String)
    case writeFile(identifier: String, name: String, json: String)
    case removeFile(identifier: String, name: String)
  }

  public struct Plan: Equatable, Sendable {
    /// In a stable order: rows first, then files, each by identifier.
    public var actions: [Action]
    /// The digests to keep for next time, assuming every action succeeds.
    public var digests: [String: String]
  }

  /// - Parameters:
  ///   - files: the folder's `.json` files.
  ///   - rows: the `themes` table, identifier → text.
  ///   - digests: what the last run returned.
  public static func plan(
    files: [ThemeFileSource], rows: [String: String], digests previous: [String: String]
  ) -> Plan {
    var claims: [String: (name: String, text: String)] = [:]
    var hasUnreadable = false
    for source in files.sorted(by: { $0.name < $1.name }) {
      guard let text = String(bytes: source.data, encoding: .utf8),
        let file = ThemeFileLoader.decode(source.data, source: source.name).0
      else {
        hasUnreadable = true
        continue
      }
      let identifier = ThemeFileLoader.identifier(of: file, source: source.name)
      // A built-in's identifier, or one an earlier file took, does not load,
      // so it is not this file's to mirror either.
      guard BuiltInThemeSpecifications.specification(withIdentifier: identifier) == nil,
        claims[identifier] == nil
      else { continue }
      claims[identifier] = (source.name, text)
    }
    let names = Set(files.map(\.name))

    var rowActions: [Action] = []
    var fileActions: [Action] = []
    var digests = previous

    for identifier in claims.keys.sorted() {
      guard let claim = claims[identifier] else { continue }
      let fileDigest = digest(claim.text)
      if let row = rows[identifier] {
        if row == claim.text {
          digests[identifier] = fileDigest
        } else if previous[identifier] == fileDigest {
          fileActions.append(.writeFile(identifier: identifier, name: claim.name, json: row))
          digests[identifier] = digest(row)
        } else {
          rowActions.append(.upsertRow(identifier: identifier, json: claim.text))
          digests[identifier] = fileDigest
        }
      } else if previous[identifier] == fileDigest {
        guard !hasUnreadable else { continue }
        fileActions.append(.removeFile(identifier: identifier, name: claim.name))
        digests[identifier] = nil
      } else {
        rowActions.append(.upsertRow(identifier: identifier, json: claim.text))
        digests[identifier] = fileDigest
      }
    }

    for identifier in rows.keys.sorted() where claims[identifier] == nil {
      guard !hasUnreadable, let json = rows[identifier] else { continue }
      if previous[identifier] != nil {
        rowActions.append(.deleteRow(identifier: identifier))
        digests[identifier] = nil
      } else {
        let name = fileName(for: identifier, json: json)
        // A file that did not claim this identifier already has the name.
        guard !names.contains(name) else { continue }
        fileActions.append(.writeFile(identifier: identifier, name: name, json: json))
        digests[identifier] = digest(json)
      }
    }

    // Gone from both sides: nothing left to remember.
    for identifier in digests.keys where rows[identifier] == nil && claims[identifier] == nil {
      digests[identifier] = nil
    }
    return Plan(actions: rowActions + fileActions, digests: digests)
  }

  /// `<identifier>.json`. A theme whose identifier comes from its file name
  /// (`user.dusk` from `dusk.json`, with no `identifier` in the file) is
  /// written under that name instead, so it reads back as the same theme.
  public static func fileName(for identifier: String, json: String) -> String {
    let file = ThemeFileLoader.decode(Data(json.utf8), source: "synced.json").0
    var stem = identifier
    let stated = file?.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if stated.isEmpty, identifier.hasPrefix(ThemeFileLoader.derivedIdentifierPrefix) {
      stem = String(identifier.dropFirst(ThemeFileLoader.derivedIdentifierPrefix.count))
    }
    let safe = stem.map { $0 == "/" || $0 == ":" ? "-" : $0 }
    return String(safe) + "." + ThemeFileLoader.fileExtension
  }

  /// SHA-256 of the text, as lowercase hex.
  public static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
