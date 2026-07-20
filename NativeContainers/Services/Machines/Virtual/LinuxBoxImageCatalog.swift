import Foundation

struct LinuxBoxImageCatalog: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  let schemaVersion: Int
  let images: [LinuxBoxImageRecord]

  init(schemaVersion: Int = Self.currentSchemaVersion, images: [LinuxBoxImageRecord]) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw LinuxBoxImageCatalogError.unsupportedSchema(schemaVersion)
    }
    guard !images.isEmpty else {
      throw LinuxBoxImageCatalogError.emptyCatalog
    }
    self.schemaVersion = schemaVersion
    self.images = images
    try validate()
  }

  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw LinuxBoxImageCatalogError.unsupportedSchema(schemaVersion)
    }
    var seen = Set<String>()
    for image in images {
      try image.validate()
      guard seen.insert(image.imageID).inserted else {
        throw LinuxBoxImageCatalogError.duplicateImageID(image.imageID)
      }
    }
  }

  static func decode(_ data: Data) throws -> LinuxBoxImageCatalog {
    let root = try StrictJSONDocument.parse(data)
    let object = try root.object(exactKeys: ["schemaVersion", "images"])
    guard let imageValues = object["images"]?.array else {
      throw LinuxBoxImageCatalogError.unknownKey
    }
    let imageKeys: Set<String> = [
      "imageID", "imageBuildRevision", "guestAgentProtocolVersion",
      "sourceURL", "sourceMetadataURL", "sourceDigestURL", "sourceSHA512",
      "rawSHA512", "releaseAssetURL", "compressedSizeBytes", "logicalSizeBytes",
      "compressedSHA256", "published",
    ]
    for image in imageValues {
      _ = try image.object(exactKeys: imageKeys)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let catalog = try decoder.decode(Self.self, from: data)
    try catalog.validate()
    return catalog
  }

  static func loadEmbedded(bundle: Bundle = .main) throws -> LinuxBoxImageCatalog {
    guard let url = bundle.url(forResource: "LinuxBoxImageCatalog", withExtension: "json") else {
      throw LinuxBoxImageCatalogError.resourceMissing
    }
    return try decode(Data(contentsOf: url))
  }

  private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, images }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let keys = Set(container.allKeys)
    guard keys == Set(CodingKeys.allCases) else {
      throw LinuxBoxImageCatalogError.unknownKey
    }
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    images = try container.decode([LinuxBoxImageRecord].self, forKey: .images)
    try validate()
  }
}

struct LinuxBoxImageRecord: Codable, Equatable, Sendable {
  let imageID: String
  let imageBuildRevision: String
  let guestAgentProtocolVersion: Int
  let sourceURL: URL
  let sourceMetadataURL: URL
  let sourceDigestURL: URL
  let sourceSHA512: String
  let rawSHA512: String
  let releaseAssetURL: URL
  let compressedSizeBytes: UInt64
  let logicalSizeBytes: UInt64
  let compressedSHA256: String
  let published: Bool

  init(
    imageID: String,
    imageBuildRevision: String,
    guestAgentProtocolVersion: Int,
    sourceURL: URL,
    sourceMetadataURL: URL,
    sourceDigestURL: URL,
    sourceSHA512: String,
    rawSHA512: String,
    releaseAssetURL: URL,
    compressedSizeBytes: UInt64,
    logicalSizeBytes: UInt64,
    compressedSHA256: String,
    published: Bool
  ) throws {
    self.imageID = imageID
    self.imageBuildRevision = imageBuildRevision
    self.guestAgentProtocolVersion = guestAgentProtocolVersion
    self.sourceURL = sourceURL
    self.sourceMetadataURL = sourceMetadataURL
    self.sourceDigestURL = sourceDigestURL
    self.sourceSHA512 = sourceSHA512
    self.rawSHA512 = rawSHA512
    self.releaseAssetURL = releaseAssetURL
    self.compressedSizeBytes = compressedSizeBytes
    self.logicalSizeBytes = logicalSizeBytes
    self.compressedSHA256 = compressedSHA256
    self.published = published
    try validate()
  }
  func validate() throws {
    guard Self.isIdentifier(imageID), Self.isIdentifier(imageBuildRevision) else {
      throw LinuxBoxImageCatalogError.invalidIdentifier
    }
    guard guestAgentProtocolVersion == 2 else {
      throw LinuxBoxImageCatalogError.invalidProtocol(guestAgentProtocolVersion)
    }
    guard sourceURL.scheme == "https", sourceMetadataURL.scheme == "https",
      sourceDigestURL.scheme == "https", releaseAssetURL.scheme == "https"
    else {
      throw LinuxBoxImageCatalogError.insecureURL
    }
    guard sourceURL.absoluteString == LinuxBoxImageCatalogPins.sourceURL,
      sourceMetadataURL.absoluteString == LinuxBoxImageCatalogPins.sourceMetadataURL,
      sourceDigestURL.absoluteString == LinuxBoxImageCatalogPins.sourceDigestURL,
      sourceSHA512 == LinuxBoxImageCatalogPins.sourceSHA512,
      releaseAssetURL.absoluteString == LinuxBoxImageCatalogPins.releaseAssetURL
    else {
      throw LinuxBoxImageCatalogError.sourceIdentityMismatch
    }
    guard Self.isDigest(sourceSHA512, length: 128),
      Self.isDigest(rawSHA512, length: 128),
      Self.isDigest(compressedSHA256, length: 64)
    else {
      throw LinuxBoxImageCatalogError.invalidDigest
    }
    if published {
      guard compressedSizeBytes > 0, logicalSizeBytes >= LinuxBoxImageCatalogPins.minimumTemplateBytes else {
        throw LinuxBoxImageCatalogError.invalidSize
      }
    }
    guard logicalSizeBytes == 0 || logicalSizeBytes >= LinuxBoxImageCatalogPins.minimumTemplateBytes else {
      throw LinuxBoxImageCatalogError.invalidSize
    }
  }

  private static func isIdentifier(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
  }

  private static func isDigest(_ value: String, length: Int) -> Bool {
    value.utf8.count == length
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case imageID, imageBuildRevision, guestAgentProtocolVersion
    case sourceURL, sourceMetadataURL, sourceDigestURL, sourceSHA512, rawSHA512
    case releaseAssetURL, compressedSizeBytes, logicalSizeBytes, compressedSHA256, published
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
      throw LinuxBoxImageCatalogError.unknownKey
    }
    imageID = try container.decode(String.self, forKey: .imageID)
    imageBuildRevision = try container.decode(String.self, forKey: .imageBuildRevision)
    guestAgentProtocolVersion = try container.decode(Int.self, forKey: .guestAgentProtocolVersion)
    sourceURL = try container.decode(URL.self, forKey: .sourceURL)
    sourceMetadataURL = try container.decode(URL.self, forKey: .sourceMetadataURL)
    sourceDigestURL = try container.decode(URL.self, forKey: .sourceDigestURL)
    sourceSHA512 = try container.decode(String.self, forKey: .sourceSHA512)
    rawSHA512 = try container.decode(String.self, forKey: .rawSHA512)
    releaseAssetURL = try container.decode(URL.self, forKey: .releaseAssetURL)
    compressedSizeBytes = try container.decode(UInt64.self, forKey: .compressedSizeBytes)
    logicalSizeBytes = try container.decode(UInt64.self, forKey: .logicalSizeBytes)
    compressedSHA256 = try container.decode(String.self, forKey: .compressedSHA256)
    published = try container.decode(Bool.self, forKey: .published)
    try validate()
  }
}

enum LinuxBoxImageCatalogPins {
  static let sourceURL = "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.raw"
  static let sourceMetadataURL = "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.json"
  static let sourceDigestURL = "https://cloud.debian.org/images/cloud/trixie/20260712-2537/SHA512SUMS"
  static let sourceSHA512 = "21f7862aca5d05a0ac8c63e64d78520967d881d05152c125b719d008f42ed2ff61e6f02908fda53a5e31a8c6e29d3a1116426e1646b9090f698c59872722d8bb"
  static let releaseAssetURL = "https://github.com/mweinbach/NativeContainers/releases/download/linux-box-image-v1/nativecontainers-debian-13-arm64-v1.raw.lzfse"
  static let minimumTemplateBytes: UInt64 = 8 * 1_073_741_824
}

enum LinuxBoxImageCatalogError: LocalizedError, Equatable, Sendable {
  case resourceMissing
  case unsupportedSchema(Int)
  case emptyCatalog
  case duplicateImageID(String)
  case unknownKey
  case invalidIdentifier
  case invalidProtocol(Int)
  case insecureURL
  case sourceIdentityMismatch
  case invalidDigest
  case invalidSize

  var errorDescription: String? {
    switch self {
    case .resourceMissing: "The embedded Linux box image catalog is missing."
    case .unsupportedSchema(let value): "Linux box image catalog schema \(value) is unsupported."
    case .emptyCatalog: "The Linux box image catalog contains no images."
    case .duplicateImageID(let value): "The Linux box image catalog repeats image \(value)."
    case .unknownKey: "The Linux box image catalog contains an unknown key."
    case .invalidIdentifier: "The Linux box image catalog contains an invalid identifier."
    case .invalidProtocol(let value): "Linux box guest protocol \(value) is unsupported."
    case .insecureURL: "Linux box image catalog URLs must use HTTPS."
    case .sourceIdentityMismatch: "The Linux box image source does not match the pinned release."
    case .invalidDigest: "The Linux box image catalog contains an invalid digest."
    case .invalidSize: "The Linux box image catalog contains an invalid size."
    }
  }
}
