import Foundation

final class CheckvistAPIClient {
  private let session: URLSession

  init(session: URLSession = CheckvistAPIClient.makeDefaultSession()) {
    self.session = session
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  static func makeDefaultSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    return URLSession(configuration: config)
  }
}
