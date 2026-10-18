import Foundation
import TaktRustCore

extension GoogleAPIScope {
  /// Reading Drive file names and types, never contents: what searching
  /// Drive by name needs. A restricted scope (docs/links.md), so asked for
  /// only once Drive search is switched on.
  static let driveMetadataReadonly = "https://www.googleapis.com/auth/drive.metadata.readonly"
  static let driveSearch: Set<String> = [driveMetadataReadonly]
}

enum GoogleDriveSearchError: LocalizedError, Equatable {
  case invalidResponse
  case apiError(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse: return "Google Drive sent something unreadable."
    case .apiError(let message): return message
    }
  }
}

/// Drive API v3 `files.list`, by name: the request and the reading of the
/// answer, kept apart from the sending so a test can hold both.
enum GoogleDriveSearch {
  static let endpoint = "https://www.googleapis.com/drive/v3/files"
  static let pageSize = 25

  /// The `q` for files whose name contains `text`, not in the bin.
  static func query(for text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    return "name contains '\(escaped)' and trashed = false"
  }

  static func request(for text: String) -> URLRequest? {
    var components = URLComponents(string: endpoint)
    components?.queryItems = [
      URLQueryItem(name: "q", value: query(for: text)),
      URLQueryItem(name: "fields", value: "files(id,name,mimeType,webViewLink)"),
      URLQueryItem(name: "pageSize", value: String(pageSize)),
      URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
      URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
      URLQueryItem(name: "supportsAllDrives", value: "true"),
    ]
    return components?.url.map { URLRequest(url: $0) }
  }

  private struct File: Decodable {
    let id: String?
    let name: String?
    let mimeType: String?
    let webViewLink: String?
  }

  private struct Response: Decodable {
    let files: [File]?
  }

  /// The files in a `files.list` answer as picker rows, linked by the
  /// address Drive gives for viewing them.
  static func candidates(from data: Data) throws -> [LinkCandidate] {
    guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
      throw GoogleDriveSearchError.invalidResponse
    }
    return (response.files ?? []).compactMap { file in
      guard let url = file.webViewLink ?? file.id.map({ "https://drive.google.com/open?id=\($0)" }) else {
        return nil
      }
      let name = file.name ?? "Untitled"
      let described = linkDescribe(url: url, title: name, mimeType: file.mimeType)
      return LinkCandidate(
        url: url, title: name, subtitle: described.subtitle, mimeType: file.mimeType,
        isFolder: described.isFolder, source: .drive, searchText: name)
    }
  }
}
