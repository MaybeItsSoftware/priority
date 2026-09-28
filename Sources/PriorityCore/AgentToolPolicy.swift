import Foundation

/// What the agent panel's assistant may do on its own, and what it has to ask.
///
/// The rule is the one the user chose: **read freely, write only with a
/// click.** The assistant gets exactly one MCP server, Priority's own (the
/// bundled `priority` CLI), and no built-in tools at all — no shell, no files,
/// no web. Of that server's tools, the ones that only read are pre-allowed on
/// the command line; everything else is left to Claude Code's permission
/// check, which with `--permission-prompt-tool stdio` asks the app, which asks
/// the user. See `docs/agent-panel.md`.
///
/// The read-only list is an allow-list rather than a deny-list on purpose. A
/// tool added to `cli/src/tools.rs` tomorrow is a write until someone puts it
/// here, so forgetting to classify one costs a click rather than a change
/// nobody saw.
public enum AgentToolPolicy {

  /// The MCP server's name in `--mcp-config`, and so the middle of every
  /// tool's qualified name: `mcp__priority__task_search`.
  public static let serverName = "priority"
  public static let toolPrefix = "mcp__\(serverName)__"

  /// The tools that change nothing, from `cli/src/tools.rs`. The Checkvist
  /// reads, the local day log and dailies, the focus clock (opened
  /// `SQLITE_OPEN_READ_ONLY` by the CLI), and the workspace tree.
  public static let readOnlyTools: [String] = [
    "task_lists", "task_fetch", "task_search", "task_metadata",
    "daily_log_fetch", "dailies_list",
    "focus_status", "focus_history",
    "workspace_tree", "workspace_tasks",
  ]

  /// The tools that write, for the docs and the tests: every one of them goes
  /// through the approval card. Not consulted to decide anything — anything
  /// not in `readOnlyTools` asks, listed here or not.
  public static let writeTools: [String] = [
    "task_add", "task_update", "task_note_add", "task_move", "task_reparent", "project_move",
    "task_complete", "task_reopen", "task_invalidate", "task_delete", "list_create",
    "task_matrix_set", "daily_add", "daily_update", "daily_tick",
    "workspace_task_add", "workspace_task_update", "workspace_task_move",
    "workspace_task_to_list", "workspace_task_delete", "workspace_folder_create",
    "workspace_list_create", "workspace_list_move",
  ]

  public static func qualifiedName(_ tool: String) -> String { toolPrefix + tool }

  /// `task_search` from `mcp__priority__task_search`; `nil` for anything that
  /// is not one of Priority's tools.
  public static func priorityToolName(_ qualified: String) -> String? {
    guard qualified.hasPrefix(toolPrefix) else { return nil }
    let bare = String(qualified.dropFirst(toolPrefix.count))
    return bare.isEmpty ? nil : bare
  }

  public static func isReadOnly(_ qualified: String) -> Bool {
    priorityToolName(qualified).map(readOnlyTools.contains) ?? false
  }

  /// What the panel does with a permission request for `qualified`.
  public enum Decision: Equatable, Sendable {
    /// Show the approval card and wait for a click.
    case askUser
    /// Refuse without asking: not one of Priority's tools, so nothing the
    /// user agreed to let the assistant have. It should never arrive —
    /// `--tools ""` and `--strict-mcp-config` leave nothing else loaded —
    /// and if it does the answer is no.
    case refuse
  }

  /// Never `allow`: there is no case for it. A read-only tool is allowed by
  /// the command line and never reaches here; if one somehow does, it asks.
  public static func decision(forPermissionRequestOn qualified: String) -> Decision {
    priorityToolName(qualified) == nil ? .refuse : .askUser
  }
}

/// The command line the panel launches, built here so it can be tested and
/// quoted in the docs exactly.
public enum AgentInvocation {

  /// The `--mcp-config` document: Priority's server and nothing else. Its
  /// environment is inherited, so the helper finds the same database and
  /// credentials the app's own MCP clients do.
  public static func mcpConfig(helperPath: String) -> String {
    JSONValue.object([
      "mcpServers": .object([
        AgentToolPolicy.serverName: .object([
          "type": .string("stdio"),
          "command": .string(helperPath),
          "args": .array([.string("--mcp-server")]),
        ])
      ])
    ]).jsonString()
  }

  /// Every argument after the executable.
  ///
  /// - `-p` with stream-json both ways keeps one process per thread, so a
  ///   follow-up is just another line on stdin.
  /// - `--tools ""` removes every built-in tool. `--strict-mcp-config` stops
  ///   the user's own MCP servers loading beside Priority's.
  /// - `--setting-sources ""` skips the user's, project's and local settings,
  ///   so no hook, plugin or permission rule written for their coding sessions
  ///   can run here or pre-approve a write.
  /// - `--permission-mode manual` is the mode that asks; `auto` and
  ///   `acceptEdits` would let a classifier or a rule answer instead.
  /// - `--permission-prompt-tool stdio` routes each question to the app.
  /// - `--no-session-persistence`: a thread lives as long as its process;
  ///   nothing is written to `~/.claude/projects`.
  public static func arguments(
    helperPath: String,
    systemPrompt: String,
    model: String? = nil
  ) -> [String] {
    var arguments = [
      "-p",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
      "--mcp-config", mcpConfig(helperPath: helperPath),
      "--strict-mcp-config",
      "--tools", "",
      "--allowedTools",
      AgentToolPolicy.readOnlyTools.map(AgentToolPolicy.qualifiedName).joined(separator: ","),
      "--permission-mode", "manual",
      "--permission-prompt-tool", "stdio",
      "--setting-sources", "",
      "--no-session-persistence",
      "--system-prompt", systemPrompt,
    ]
    if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
      arguments += ["--model", model]
    }
    return arguments
  }
}

/// Where the user's Claude Code is.
///
/// A GUI app does not see the shell's `PATH` — or its aliases, which is how
/// `claude` is often spelled — so the binary is looked for where the installer
/// puts it, after a path the user set by hand.
public enum AgentCLILocator {

  public static let userPathDefaultsKey = "agentClaudeExecutablePathV1"

  public static func candidates(userPath: String?, homeDirectory: String) -> [String] {
    var candidates: [String] = []
    if let trimmed = userPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
      candidates.append((trimmed as NSString).expandingTildeInPath)
    }
    candidates += [
      "\(homeDirectory)/.local/bin/claude",
      "\(homeDirectory)/.claude/local/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ]
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  public static func resolve(candidates: [String], isExecutable: (String) -> Bool) -> String? {
    candidates.first(where: isExecutable)
  }
}

/// What the assistant is told about where it is.
public enum AgentSystemPrompt {

  /// The system prompt for a thread. Replaces Claude Code's own, which is
  /// about writing software with tools this process does not have.
  public static func text(today: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE d MMMM yyyy"
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.timeZone = timeZone
    iso.dateFormat = "yyyy-MM-dd"
    return """
      You are the assistant inside Priority, a keyboard-first macOS task app. You help the \
      user understand, plan and organise their tasks. Today is \(formatter.string(from: today)) \
      (\(iso.string(from: today))).

      You have Priority's own tools and nothing else: no shell, no files, no web. The \
      workspace_* tools read and edit the app's own lists and tasks, which are the source of \
      truth; ids there are uppercase UUIDs. The task_* tools reach Checkvist, an optional \
      integration the user may not have set up. Use the read tools freely to answer questions.

      Every change — adding, editing, completing, moving or deleting anything — is shown to the \
      user as a card and only runs if they approve it. So before calling a tool that writes, say \
      in one sentence what you are about to change, then call it with exactly that change. Make \
      one change per call, so each can be approved or declined on its own. If a change is \
      declined, do not retry it; ask what they would like instead.

      Reply in short, plain Markdown. Refer to tasks and lists by their titles, not their ids.
      """
  }

  /// A line prefixed to each message, saying what the user is looking at, so
  /// "this task" and "this list" mean something. Sent to the assistant, not
  /// shown in the transcript.
  public static func context(
    listName: String?, listID: String?, taskTitle: String?, taskID: String?
  ) -> String? {
    var parts: [String] = []
    if let listName, !listName.isEmpty {
      parts.append("list \"\(listName)\"" + (listID.map { " (id \($0))" } ?? ""))
    }
    if let taskTitle, !taskTitle.isEmpty {
      parts.append("selected task \"\(taskTitle)\"" + (taskID.map { " (id \($0))" } ?? ""))
    }
    guard !parts.isEmpty else { return nil }
    return "[The user is looking at \(parts.joined(separator: ", with "))]"
  }
}
