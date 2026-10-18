import Foundation
import TaktRustCore

/// A link as a client draws it: where it points, what it is, and an icon
/// hint. Read from the address and the name the picker stored, by the Rust
/// core (`links::link_describe`). See docs/links.md.
public struct WorkspaceTaskLink: Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case drive, obsidian, web
  }

  /// The address, as stored and as opened.
  public let url: String
  public let kind: Kind
  public let title: String
  /// What it is and where: "Google Sheet", "Life · Projects", a host.
  public let subtitle: String
  /// `doc`, `sheet`, `slides`, `form`, `pdf`, `image`, `file`, `folder`,
  /// `note` or `web`.
  public let icon: String
  public let mimeType: String?
  public let isFolder: Bool

  init(_ core: TaskLink) {
    url = core.url
    switch core.kind {
    case .drive: kind = .drive
    case .obsidian: kind = .obsidian
    case .web: kind = .web
    }
    title = core.title
    subtitle = core.subtitle
    icon = core.icon
    mimeType = core.mimeType
    isFolder = core.isFolder
  }

  /// `url` described, with the name and type a picker knew.
  public static func describe(_ url: String, title: String? = nil, mimeType: String? = nil) -> WorkspaceTaskLink {
    WorkspaceTaskLink(linkDescribe(url: url, title: title, mimeType: mimeType))
  }

  /// The address in `text` if the whole of it, trimmed, is one a task can
  /// link to (`http`, `https` or `obsidian`); nil otherwise.
  public static func address(in text: String) -> String? {
    linkFromText(text: text)
  }

  /// The address that opens `path` in the Obsidian vault named `vault`; a
  /// folder opens as a search scoped to it.
  public static func obsidianAddress(vault: String, path: String, isFolder: Bool) -> String {
    obsidianLinkUrl(vault: vault, path: path, isFolder: isFolder)
  }
}

/// A task's links: Drive files and folders, Obsidian notes and folders, web
/// pages. The addresses, the names the picker stored and how each is drawn
/// are the Rust core's (core/src/links.rs); see docs/links.md.
extension WorkspaceStore {

  /// The task's links in the order they were added, each described for
  /// drawing.
  public func links(of taskId: String) throws -> [WorkspaceTaskLink] {
    try Self.mappingCoreErrors { try core.taskLinks(taskId: taskId) }.map(WorkspaceTaskLink.init)
  }

  /// Every task with at least one link: the rows that show the link mark.
  public func linkedTaskIds() throws -> Set<String> {
    Set(try Self.mappingCoreErrors { try core.linkedTaskIds() })
  }

  /// Links `url` to `taskId` as one "Add Link" undo step, with the name and
  /// file type the picker knew. Returns whether the address is new; one
  /// already there takes the name.
  @discardableResult
  public func addLink(
    _ url: String, title: String? = nil, mimeType: String? = nil, to taskId: String, now: Date = .now
  ) throws -> Bool {
    try coreWrite {
      try core.addTaskLink(
        taskId: taskId, url: url, title: title, mimeType: mimeType, nowMs: now.coreMilliseconds)
    }
  }

  /// Takes `url` off `taskId`'s links as one "Remove Link" undo step.
  @discardableResult
  public func removeLink(_ url: String, from taskId: String, now: Date = .now) throws -> Bool {
    try coreWrite { try core.removeTaskLink(taskId: taskId, url: url, nowMs: now.coreMilliseconds) }
  }
}
