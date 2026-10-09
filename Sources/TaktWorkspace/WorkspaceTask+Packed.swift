import Foundation

/// Task rows the Rust core packed into one buffer (`core/src/packed_rows.rs`,
/// which documents the layout), decoded here in one pass over raw memory.
///
/// UniFFI's own lifting reads every field of every record on its own, out of
/// `Data`, and copies each string into an array of its own before it becomes
/// a `String`: that, not the core's work, was most of what a big read cost.
/// The answer is the same `WorkspaceTask`s `WorkspaceTask(TaskRow)` makes; a
/// test holds the two to it.
enum PackedTaskRows {
  struct Malformed: Error {}

  private static let parent: UInt16 = 1 << 0
  private static let due: UInt16 = 1 << 1
  private static let estimate: UInt16 = 1 << 2
  private static let sourceSystem: UInt16 = 1 << 3
  private static let sourceId: UInt16 = 1 << 4
  private static let itemKind: UInt16 = 1 << 5
  private static let promoted: UInt16 = 1 << 6
  private static let promotedValue: UInt16 = 1 << 7
  private static let archived: UInt16 = 1 << 8
  private static let completed: UInt16 = 1 << 9

  static func decode(_ data: Data) throws -> [WorkspaceTask] {
    try data.withUnsafeBytes { raw in
      var reader = Reader(raw: raw)
      let count = Int(try reader.u32())
      var tasks: [WorkspaceTask] = []
      // A row is at least 46 bytes, so a corrupt count cannot reserve much.
      tasks.reserveCapacity(min(count, raw.count / 46))
      for _ in 0..<count {
        let flags = try reader.u16()
        let sortOrder = try reader.i64()
        let createdAt = try reader.i64()
        let updatedAt = try reader.i64()
        let dueAt = flags & due != 0 ? try reader.i64() : nil
        let estimateSeconds = flags & estimate != 0 ? try reader.i64() : nil
        let archivedAt = flags & archived != 0 ? try reader.i64() : nil
        let completedAt = flags & completed != 0 ? try reader.i64() : nil
        let id = try reader.string()
        let listId = try reader.listId()
        let title = try reader.string()
        let notes = try reader.string()
        let status = try reader.string()
        let parentTaskId = flags & parent != 0 ? try reader.string() : nil
        let sourceSystem = flags & sourceSystem != 0 ? try reader.string() : nil
        let sourceId = flags & sourceId != 0 ? try reader.string() : nil
        let itemKind = flags & itemKind != 0 ? try reader.string() : nil
        tasks.append(WorkspaceTask(
          id: id, listId: listId, parentTaskId: parentTaskId, title: title, notes: notes,
          status: TaskStatus(rawValue: status) ?? .open, sortOrder: Int(sortOrder),
          dueAt: dueAt.map(Date.init(coreMilliseconds:)), estimateSeconds: estimateSeconds.map { Int($0) },
          sourceSystem: sourceSystem, sourceId: sourceId,
          itemKind: itemKind.flatMap(WorkspaceItemKind.init(rawValue:)),
          isPromoted: flags & promoted != 0 ? flags & promotedValue != 0 : nil,
          archivedAt: archivedAt.map(Date.init(coreMilliseconds:)),
          completedAt: completedAt.map(Date.init(coreMilliseconds:)),
          createdAt: Date(coreMilliseconds: createdAt), updatedAt: Date(coreMilliseconds: updatedAt)))
      }
      guard reader.offset == raw.count else { throw Malformed() }
      return tasks
    }
  }

  private struct Reader {
    let raw: UnsafeRawBufferPointer
    var offset = 0
    /// The last list id read, and its bytes' place, so a run of rows from
    /// one list shares one string rather than making one each.
    private var lastListId: (start: Int, count: Int, value: String)?

    init(raw: UnsafeRawBufferPointer) {
      self.raw = raw
    }

    private mutating func advance(_ count: Int) throws -> Int {
      let start = offset
      guard count >= 0, count <= raw.count - start else { throw Malformed() }
      offset = start + count
      return start
    }

    mutating func u16() throws -> UInt16 {
      UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(2), as: UInt16.self))
    }

    mutating func u32() throws -> UInt32 {
      UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(4), as: UInt32.self))
    }

    mutating func i64() throws -> Int64 {
      Int64(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(8), as: Int64.self))
    }

    private mutating func bytes() throws -> UnsafeRawBufferPointer {
      let count = Int(try u32())
      let start = try advance(count)
      return UnsafeRawBufferPointer(rebasing: raw[start..<start + count])
    }

    mutating func string() throws -> String {
      String(decoding: try bytes(), as: UTF8.self)
    }

    mutating func listId() throws -> String {
      let bytes = try bytes()
      let start = bytes.baseAddress.map { $0 - raw.baseAddress! } ?? 0
      if let last = lastListId, last.count == bytes.count,
         memcmp(raw.baseAddress! + last.start, raw.baseAddress! + start, bytes.count) == 0 {
        return last.value
      }
      let value = String(decoding: bytes, as: UTF8.self)
      lastListId = (start, bytes.count, value)
      return value
    }
  }
}
