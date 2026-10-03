import Darwin
import Foundation
import PriorityCore

/// `Takt --mcp-server` hands the process over to the bundled `takt` CLI,
/// which is the MCP server.
///
/// There used to be a second, in-process implementation — 1,760 lines of Swift
/// in `Plugins/MCP/MCPServer.swift` — kept alive by one thing: MCP client
/// configurations already written to users' disks name
/// `/Applications/Priority.app/Contents/MacOS/Priority --mcp-server` (the app's
/// name before Takt). Deleting it would have broken every one of them.
///
/// So the app ships the CLI instead (`Contents/Helpers/takt`, installed by
/// `scripts/bundle_cli.sh`) and this hands over to it. Those configs keep
/// working untouched, because the CLI already accepts the bare `--mcp-server`
/// flag for exactly this reason (`cli/src/main.rs`) and already reads
/// credentials from the environment ahead of its own config file
/// (`cli/src/config.rs`) — which is where a client config puts them.
///
/// `execve` rather than a child process: the client owns this process's stdio
/// and expects it to live exactly as long as the server does. Replacing the
/// image means there is no supervision to get wrong — no orphan left behind
/// when stdin closes, which the old in-process path needed an explicit
/// `explicitQuitRequested` dance to avoid.
enum MCPServerShim {

  static func isLaunchMode(arguments: [String]) -> Bool {
    arguments.contains("--mcp-server")
  }

  /// Where the CLI might be, most specific first. The search order itself
  /// lives in `MCPHelperLocator` so it can be tested.
  static func helperCandidates(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleURL: URL = Bundle.main.bundleURL
  ) -> [String] {
    MCPHelperLocator.candidates(
      environmentOverride: environment["PRIORITY_MCP_EXECUTABLE_PATH"],
      bundlePath: bundleURL.path,
      homeDirectory: environment["HOME"] ?? NSHomeDirectory())
  }

  /// Never returns on success — the process becomes the CLI.
  static func run() -> Never {
    let candidates = helperCandidates()
    guard
      let helper = MCPHelperLocator.resolve(
        candidates: candidates,
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      FileHandle.standardError.write(
        Data((MCPHelperLocator.missingHelperMessage(candidates: candidates) + "\n").utf8))
      exit(127)
    }

    // The environment carries over untouched, which is what makes an existing
    // client config's credentials keep working.
    let arguments =
      [helper] + MCPHelperLocator.forwardedArguments(from: ProcessInfo.processInfo.arguments)

    var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    pointers.append(nil)
    execv(helper, &pointers)

    // Only reachable if execv failed.
    FileHandle.standardError.write(
      Data("takt: could not start \(helper): \(String(cString: strerror(errno)))\n".utf8))
    exit(126)
  }
}
