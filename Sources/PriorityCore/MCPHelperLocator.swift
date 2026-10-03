import Foundation

/// Where `Takt --mcp-server` finds the CLI to hand over to.
///
/// The MCP server is the `takt` CLI, shipped inside the app bundle at
/// `Contents/Helpers/takt`. This is the pure half of `MCPServerShim` — the
/// search order and the diagnostic — so both can be tested without launching a
/// process.
public enum MCPHelperLocator {

  public static let bundleRelativePath = "Contents/Helpers/takt"

  /// Most specific first.
  public static func candidates(
    environmentOverride: String?,
    bundlePath: String,
    homeDirectory: String
  ) -> [String] {
    var candidates: [String] = []

    // An explicit override wins, so a development build can be pointed at a
    // freshly built CLI without reinstalling the app.
    if let trimmed = environmentOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    {
      candidates.append(trimmed)
    }

    candidates.append(
      URL(fileURLWithPath: bundlePath).appendingPathComponent(bundleRelativePath).path)

    // A separately installed CLI, for a bundle built with
    // PRIORITY_SKIP_CLI_BUNDLE=1 or run straight out of DerivedData.
    candidates.append(contentsOf: [
      "\(homeDirectory)/.local/bin/takt",
      "\(homeDirectory)/bin/takt",
      "/usr/local/bin/takt",
      "/opt/homebrew/bin/takt",
    ])

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  public static func resolve(candidates: [String], isExecutable: (String) -> Bool) -> String? {
    candidates.first(where: isExecutable)
  }

  /// Written to stderr, where an MCP client surfaces it in its own logs — the
  /// only channel available, since stdout carries the protocol. It names every
  /// path tried, because "not found" without the search order is the kind of
  /// error that costs an afternoon.
  public static func missingHelperMessage(candidates: [String]) -> String {
    """
    takt: no MCP server to run.

    `Takt --mcp-server` hands over to the bundled `takt` CLI, which was \
    not found. Looked in:
    \(candidates.map { "  \($0)" }.joined(separator: "\n"))

    Install it with ./scripts/install_cli.sh, or set \
    PRIORITY_MCP_EXECUTABLE_PATH to the binary.
    """
  }

  /// Everything from `--mcp-server` onwards is forwarded, so a future CLI flag
  /// needs no change in the shim.
  public static func forwardedArguments(from arguments: [String]) -> [String] {
    Array(arguments.drop(while: { $0 != "--mcp-server" }))
  }
}
