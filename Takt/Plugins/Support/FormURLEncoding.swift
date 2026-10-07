import Foundation

/// `application/x-www-form-urlencoded` value encoding, shared by every plugin
/// that posts a form (Checkvist's task endpoints, Google's token endpoint).
enum FormURLEncoding {
  /// RFC 3986 unreserved characters. Everything else — including `+`, `&`,
  /// `=` and space, which the broader `.urlQueryAllowed` set lets through and
  /// a form parser then misreads — is percent-encoded.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func percentEncodeFormValue(_ raw: String) -> String {
    // Force-unwrap is safe: addingPercentEncoding only returns nil for invalid
    // UTF-16 surrogates, which Swift's String type cannot represent.
    raw.addingPercentEncoding(withAllowedCharacters: unreserved)!
  }
}
