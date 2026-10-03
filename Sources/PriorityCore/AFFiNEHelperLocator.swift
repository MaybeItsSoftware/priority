import Foundation

/// Where the AFFiNE integration finds `affine-mcp`, and what PATH to run it
/// with.
///
/// The helper is not ours and is not bundled: it is the `affine-mcp-server` npm
/// package, installed by the user. The pure half of that lookup lives here so
/// the search order and the diagnostic can be tested without a filesystem —
/// the same split as `MCPHelperLocator`, which does this for our own CLI.
public enum AFFiNEHelperLocator {

  public static let helperName = "affine-mcp"

  /// Set to point a build at a specific install without touching settings.
  public static let environmentOverrideKey = "PRIORITY_AFFINE_MCP_PATH"

  /// Most specific first: an explicit setting beats an environment override
  /// beats whatever is lying around on disk.
  ///
  /// - Parameter nodeVersionDirectories: absolute paths to nvm's per-version
  ///   directories (`~/.nvm/versions/node/v22.0.0`). Passed in rather than
  ///   globbed here, because globbing is a filesystem read and this is not.
  ///   Newest-first is the caller's job — the order given is the order tried.
  public static func candidates(
    configuredPath: String?,
    environmentOverride: String?,
    homeDirectory: String,
    nodeVersionDirectories: [String] = []
  ) -> [String] {
    var candidates: [String] = []

    for explicit in [configuredPath, environmentOverride] {
      let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty {
        candidates.append(trimmed)
      }
    }

    candidates.append(contentsOf: nodeVersionDirectories.map { "\($0)/bin/\(helperName)" })

    candidates.append(contentsOf: [
      "\(homeDirectory)/.local/bin/\(helperName)",
      "\(homeDirectory)/.npm-global/bin/\(helperName)",
      "\(homeDirectory)/node_modules/.bin/\(helperName)",
      "/opt/homebrew/bin/\(helperName)",
      "/usr/local/bin/\(helperName)",
    ])

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  public static func resolve(candidates: [String], isExecutable: (String) -> Bool) -> String? {
    candidates.first(where: isExecutable)
  }

  /// The PATH to launch the helper with.
  ///
  /// `affine-mcp` is a `#!/usr/bin/env node` script, so it only starts if
  /// `node` is on PATH — and a menu bar app launched by the OS inherits a PATH
  /// that, under nvm, does not include one. Prepending the helper's own
  /// directory fixes the common case for free: an npm-installed binary sits in
  /// the same `bin` as the `node` that installed it.
  public static func searchPath(forHelperPath helperPath: String, basePATH: String) -> String {
    let helperDirectory = (helperPath as NSString).deletingLastPathComponent
    var components = basePATH.split(separator: ":").map(String.init)
    if !helperDirectory.isEmpty {
      components.removeAll { $0 == helperDirectory }
      components.insert(helperDirectory, at: 0)
    }

    var seen = Set<String>()
    return components.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
  }

  /// Names every path tried. "Not found" without the search order is the kind
  /// of error that costs an afternoon.
  public static func missingHelperMessage(candidates: [String]) -> String {
    """
    Takt could not find `affine-mcp`.

    The AFFiNE integration talks to your workspace through the \
    `affine-mcp-server` npm package, which was not found. Looked in:
    \(candidates.map { "  \($0)" }.joined(separator: "\n"))

    Install it with `npm install -g affine-mcp-server`, then sign in with \
    `affine-mcp login`. If it lives somewhere else, set the path in \
    Settings → AFFiNE.
    """
  }
}
