import Foundation
import XCTest

@testable import PriorityPlugins

@MainActor
final class NativeMCPIntegrationPluginTests: XCTestCase {
  func testMakeClientConfigurationJSONCarriesTheListIdOverride() throws {
    let plugin = NativeMCPIntegrationPlugin()

    let json = plugin.makeClientConfigurationJSON(listId: " 123 ")
    let root = try decodeJSON(json)

    let env = try XCTUnwrap(root["env"] as? [String: Any])
    XCTAssertEqual(env["CHECKVIST_LIST_ID"] as? String, "123")
  }

  /// The env block must never pin credentials: the CLI reads its config file
  /// only for variables the environment doesn't set, so a key here would both
  /// go stale on rotation and shut out the store the app seeds.
  func testMakeClientConfigurationJSONCarriesNoCredentials() throws {
    let plugin = NativeMCPIntegrationPlugin()

    let json = plugin.makeClientConfigurationJSON(listId: "123")
    XCTAssertFalse(json.contains("CHECKVIST_USERNAME"))
    XCTAssertFalse(json.contains("CHECKVIST_REMOTE_KEY"))

    let env = try XCTUnwrap(try decodeJSON(json)["env"] as? [String: Any])
    XCTAssertEqual(Set(env.keys), ["CHECKVIST_LIST_ID"])
  }

  /// An empty `env` is omitted rather than written as `{}` — there is nothing
  /// the server needs from it when there is no list override.
  func testMakeClientConfigurationJSONOmitsAnEmptyEnvironment() throws {
    let plugin = NativeMCPIntegrationPlugin()

    let root = try decodeJSON(plugin.makeClientConfigurationJSON(listId: "  "))
    XCTAssertNil(root["env"])
    XCTAssertNotNil(root["command"])
  }

  private func decodeJSON(_ json: String) throws -> [String: Any] {
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
    return try XCTUnwrap(servers["takt"] as? [String: Any])
  }
}
