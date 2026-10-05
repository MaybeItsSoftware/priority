import Foundation
import XCTest

@testable import TaktPlugins

final class UserPluginManifestTests: XCTestCase {
  func testManifestDecodesDescriptionIntoSummary() throws {
    let data = Data(
      #"""
      {
        "id": "test.plugin",
        "name": "Test Plugin",
        "description": "Legacy description field",
        "capabilities": ["task.sync"]
      }
      """#.utf8
    )

    let manifest = try JSONDecoder().decode(UserPluginManifest.self, from: data)

    XCTAssertEqual(manifest.id, "test.plugin")
    XCTAssertEqual(manifest.name, "Test Plugin")
    XCTAssertEqual(manifest.summary, "Legacy description field")
    XCTAssertEqual(manifest.capabilities, ["task.sync"])
    XCTAssertEqual(manifest.settingsSchema, [])
  }

  func testManifestDefaultsOptionalCollections() throws {
    let data = Data(
      #"""
      {
        "id": "minimal.plugin",
        "name": "Minimal Plugin"
      }
      """#.utf8
    )

    let manifest = try JSONDecoder().decode(UserPluginManifest.self, from: data)

    XCTAssertEqual(manifest.capabilities, [])
    XCTAssertEqual(manifest.settingsSchema, [])
    XCTAssertNil(manifest.summary)
    XCTAssertNil(manifest.version)
    XCTAssertNil(manifest.pluginApiVersion)
    XCTAssertNil(manifest.minAppVersion)
  }

  func testManifestDecodesCompatibilityFields() throws {
    let data = Data(
      #"""
      {
        "id": "compat.plugin",
        "name": "Compat Plugin",
        "pluginApiVersion": "1",
        "minAppVersion": "1.4.0"
      }
      """#.utf8
    )

    let manifest = try JSONDecoder().decode(UserPluginManifest.self, from: data)
    XCTAssertEqual(manifest.pluginApiVersion, 1)
    XCTAssertEqual(manifest.minAppVersion, "1.4.0")
  }

  func testSettingSchemaDefaultValueSupportsNumberAndBoolFormats() throws {
    let data = Data(
      #"""
      {
        "id": "settings.plugin",
        "name": "Settings Plugin",
        "settingsSchema": [
          {
            "key": "maxItems",
            "title": "Max Items",
            "type": "number",
            "defaultValue": 15
          },
          {
            "key": "enabled",
            "title": "Enabled",
            "type": "bool",
            "defaultValue": true
          }
        ]
      }
      """#.utf8
    )

    let manifest = try JSONDecoder().decode(UserPluginManifest.self, from: data)
    XCTAssertEqual(manifest.settingsSchema.count, 2)

    XCTAssertEqual(manifest.settingsSchema[0].defaultValue, "15")
    XCTAssertNil(manifest.settingsSchema[0].defaultBool)
    XCTAssertEqual(manifest.settingsSchema[1].defaultBool, true)
  }
}
