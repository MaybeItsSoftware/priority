import Foundation

/// Which coding agent the agent panel runs: the user's own CLI, headless,
/// with Takt's MCP server as its tools.
///
/// Distinct from `MCPClientCatalog`, which is every app Takt can add its MCP
/// server to. Most of those — Claude Desktop, Cursor, VS Code, Zed — are
/// editors with an agent inside, not a command the panel can start and talk
/// to over a pipe. These are the ones it can: each has a headless mode that
/// takes Takt's server on the command line and streams its turn back as
/// JSON lines.
///
/// The choice is kept in `UserDefaults` (`defaultsKey`) and read when a
/// thread starts, so changing it leaves a running thread on the agent it
/// started with. See `docs/agent-panel.md`.
public enum AgentClient: String, CaseIterable, Identifiable, Sendable {
  case claudeCode = "claude-code"
  case codex

  public var id: String { rawValue }

  /// `UserDefaults`: the agent new threads use.
  public static let defaultsKey = "agentClientV1"

  /// The stored choice, or Claude Code — the panel's only agent before there
  /// was a choice — when there is none or it names one this build lacks.
  public static func stored(_ raw: String?) -> AgentClient {
    raw.flatMap(AgentClient.init(rawValue:)) ?? .claudeCode
  }

  public var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    }
  }

  /// The binary's name, as the installers leave it.
  public var executableName: String {
    switch self {
    case .claudeCode: "claude"
    case .codex: "codex"
    }
  }

  /// `UserDefaults`: a path to the binary set by hand. Claude Code's is the
  /// key it had before there was a choice, so a path set then still holds.
  public var userPathDefaultsKey: String {
    switch self {
    case .claudeCode: AgentCLILocator.userPathDefaultsKey
    case .codex: "agentCodexExecutablePathV1"
    }
  }

  /// Whether a write can stop and wait for Approve. Claude Code asks its host
  /// over stdio; Codex's headless mode has no one to ask, so with "Ask
  /// before changing tasks" on, a Codex thread is given only the reads.
  public var canAskBeforeChanges: Bool { self == .claudeCode }

  /// Who the agent belongs to, for "could not reach …".
  public var provider: String {
    switch self {
    case .claudeCode: "Anthropic"
    case .codex: "OpenAI"
    }
  }

  /// Where to get it and how to sign in, for the panel's setup state.
  public var installHint: String {
    switch self {
    case .claudeCode:
      "Install it from claude.com/claude-code and sign in once in a terminal (`claude`), or give the path to "
        + "an existing `claude` binary below. No API key is needed; it uses your Claude Code login."
    case .codex:
      "Install it (`brew install codex` or `npm install -g @openai/codex`) and sign in once in a terminal "
        + "(`codex login`), or give the path to an existing `codex` binary below. It uses your Codex login."
    }
  }

  /// Where the binary is looked for, first match wins: a path set by hand,
  /// then where each installer puts it.
  public func candidates(userPath: String?, homeDirectory: String) -> [String] {
    var candidates: [String] = []
    if let trimmed = userPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
      candidates.append((trimmed as NSString).expandingTildeInPath)
    }
    switch self {
    case .claudeCode:
      candidates += [
        "\(homeDirectory)/.local/bin/claude",
        "\(homeDirectory)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
      ]
    case .codex:
      candidates += [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(homeDirectory)/.local/bin/codex",
        "\(homeDirectory)/.npm-global/bin/codex",
      ]
    }
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }
}
