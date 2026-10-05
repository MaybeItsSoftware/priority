import Foundation

struct UserPluginManifest: Codable, Hashable {
  static let defaultPluginAPIVersion = 1

  let id: String
  let name: String
  let version: String?
  let pluginApiVersion: Int?
  let minAppVersion: String?
  let summary: String?
  let iconSystemName: String?
  let capabilities: [String]
  let entrypoint: String?
  let settingsSchema: [UserPluginSettingSchemaField]

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case version
    case pluginApiVersion
    case minAppVersion
    case summary
    case description
    case iconSystemName
    case capabilities
    case entrypoint
    case settingsSchema
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    version = try container.decodeIfPresent(String.self, forKey: .version)

    if let decodedInt = try? container.decodeIfPresent(Int.self, forKey: .pluginApiVersion) {
      pluginApiVersion = decodedInt
    } else if let decodedString = try? container.decodeIfPresent(
      String.self, forKey: .pluginApiVersion),
      let parsedInt = Int(decodedString.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      pluginApiVersion = parsedInt
    } else {
      pluginApiVersion = nil
    }

    minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
    summary =
      try container.decodeIfPresent(String.self, forKey: .summary)
      ?? container.decodeIfPresent(String.self, forKey: .description)
    iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
    settingsSchema =
      try container.decodeIfPresent([UserPluginSettingSchemaField].self, forKey: .settingsSchema)
      ?? []
  }

  init(
    id: String,
    name: String,
    version: String?,
    pluginApiVersion: Int?,
    minAppVersion: String?,
    summary: String?,
    iconSystemName: String?,
    capabilities: [String],
    entrypoint: String?,
    settingsSchema: [UserPluginSettingSchemaField]
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.pluginApiVersion = pluginApiVersion
    self.minAppVersion = minAppVersion
    self.summary = summary
    self.iconSystemName = iconSystemName
    self.capabilities = capabilities
    self.entrypoint = entrypoint
    self.settingsSchema = settingsSchema
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(version, forKey: .version)
    try container.encodeIfPresent(pluginApiVersion, forKey: .pluginApiVersion)
    try container.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
    try container.encodeIfPresent(summary, forKey: .summary)
    try container.encodeIfPresent(iconSystemName, forKey: .iconSystemName)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
    try container.encode(settingsSchema, forKey: .settingsSchema)
  }
}

enum UserPluginSettingFieldType: String, Codable, CaseIterable {
  case string
  case bool
  case number
  case select
}

struct UserPluginSettingSchemaOption: Codable, Hashable, Identifiable {
  let value: String
  let label: String

  var id: String { value }
}

struct UserPluginSettingSchemaField: Codable, Hashable, Identifiable {
  let key: String
  let title: String
  let type: UserPluginSettingFieldType
  let help: String?
  let placeholder: String?
  let defaultValue: String?
  let defaultBool: Bool?
  let options: [UserPluginSettingSchemaOption]

  var id: String { key }

  enum CodingKeys: String, CodingKey {
    case key
    case title
    case type
    case help
    case placeholder
    case defaultValue
    case defaultBool
    case options
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    title = try container.decode(String.self, forKey: .title)
    type = try container.decode(UserPluginSettingFieldType.self, forKey: .type)
    help = try container.decodeIfPresent(String.self, forKey: .help)
    placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)

    let decodedString = try? container.decodeIfPresent(String.self, forKey: .defaultValue)
    let decodedInt = try? container.decodeIfPresent(Int.self, forKey: .defaultValue)
    let decodedDouble = try? container.decodeIfPresent(Double.self, forKey: .defaultValue)
    if let decodedString {
      defaultValue = decodedString
    } else if let decodedInt {
      defaultValue = String(decodedInt)
    } else if let decodedDouble {
      defaultValue = String(decodedDouble)
    } else {
      defaultValue = nil
    }

    defaultBool =
      (try? container.decodeIfPresent(Bool.self, forKey: .defaultBool))
      ?? (try? container.decodeIfPresent(Bool.self, forKey: .defaultValue))
    options =
      try container.decodeIfPresent([UserPluginSettingSchemaOption].self, forKey: .options)
      ?? []
  }

  init(
    key: String,
    title: String,
    type: UserPluginSettingFieldType,
    help: String? = nil,
    placeholder: String? = nil,
    defaultValue: String? = nil,
    defaultBool: Bool? = nil,
    options: [UserPluginSettingSchemaOption] = []
  ) {
    self.key = key
    self.title = title
    self.type = type
    self.help = help
    self.placeholder = placeholder
    self.defaultValue = defaultValue
    self.defaultBool = defaultBool
    self.options = options
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(title, forKey: .title)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(help, forKey: .help)
    try container.encodeIfPresent(placeholder, forKey: .placeholder)
    try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    try container.encodeIfPresent(defaultBool, forKey: .defaultBool)
    try container.encode(options, forKey: .options)
  }
}
