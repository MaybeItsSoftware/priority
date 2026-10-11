import Foundation
import TaktRustCore

// The Checkvist conversation is the core's (`core/src/checkvist.rs`), shared
// with the CLI: what each request looks like and how each answer reads. This
// file only moves values between its rows and the Mac's models, and turns its
// requests into `URLRequest`s; sending them stays with `CheckvistSession`.

extension CheckvistNote {
  init(core row: CheckvistNoteRow) {
    self.init(
      id: row.id.map(Int.init), content: row.content, createdAt: row.createdAt, updatedAt: row.updatedAt)
  }

  var coreRow: CheckvistNoteRow {
    CheckvistNoteRow(id: id.map(Int64.init), content: content, createdAt: createdAt, updatedAt: updatedAt)
  }
}

extension CheckvistTask {
  init(core row: CheckvistTaskRow) {
    self.init(
      id: Int(row.id),
      content: row.content,
      status: Int(row.status),
      due: row.due,
      position: row.position.map(Int.init),
      parentId: row.parentId.map(Int.init),
      level: row.level.map(Int.init),
      notes: row.notes?.map(CheckvistNote.init(core:)),
      updatedAt: row.updatedAt)
  }

  var coreRow: CheckvistTaskRow {
    CheckvistTaskRow(
      id: Int64(id),
      content: content,
      status: Int64(status),
      due: due,
      position: position.map(Int64.init),
      parentId: parentId.map(Int64.init),
      level: level.map(Int64.init),
      notes: notes?.map(\.coreRow),
      updatedAt: updatedAt)
  }
}

extension CheckvistList {
  init(core row: CheckvistListRow) {
    self.init(id: Int(row.id), name: row.name, archived: row.archived, readOnly: row.readOnly)
  }
}

enum CheckvistWire {
  /// The request the core shapes for `call`, against Checkvist's address,
  /// carrying `token` when there is one.
  static func request(_ call: CheckvistCall, token: String?) throws -> URLRequest {
    let shaped = try checkvistRequest(
      baseUrl: CheckvistEndpoints.baseURL, call: call, token: token, userAgent: CheckvistEndpoints.userAgent)
    guard let url = URL(string: shaped.url) else {
      throw CheckvistSessionError.invalidResponse(statusCode: nil)
    }
    var request = URLRequest(url: url)
    request.httpMethod = shaped.method
    for header in shaped.headers {
      request.setValue(header.value, forHTTPHeaderField: header.name)
    }
    request.httpBody = shaped.body.map { Data($0.utf8) }
    return request
  }

  /// A response body as the text the core reads.
  static func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
  }

  /// The workspace import's seeds for `tasks`, each source id `prefix` and
  /// the task's Checkvist id.
  static func importSeeds(prefix: String, tasks: [CheckvistTask]) -> [TaktRustCore.ImportedTaskSeed] {
    checkvistImportSeeds(sourcePrefix: prefix, tasks: tasks.map(\.coreRow))
  }
}
