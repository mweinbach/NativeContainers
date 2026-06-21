import Foundation

struct MacVirtualMachineDiskSnapshotLayer: Codable, Equatable, Sendable, Identifiable {
  static let directoryName = "Snapshots"
  static let fileExtension = "asif"

  let id: UUID
  let relativePath: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    createdAt: Date = Date()
  ) {
    self.id = id
    relativePath = Self.relativePath(for: id)
    self.createdAt = createdAt
  }

  static func relativePath(for id: UUID) -> String {
    "\(directoryName)/\(id.uuidString).\(fileExtension)"
  }

  var isCanonical: Bool {
    relativePath == Self.relativePath(for: id)
  }
}

struct MacVirtualMachineDiskSnapshot: Codable, Equatable, Sendable, Identifiable {
  static let maximumNameLength = 80

  let id: UUID
  let name: String
  let createdAt: Date
  let capturedLayerCount: Int

  init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date(),
    capturedLayerCount: Int
  ) throws {
    let normalizedName = try Self.normalizedName(name)
    self.id = id
    self.name = normalizedName
    self.createdAt = createdAt
    self.capturedLayerCount = capturedLayerCount
  }

  static func normalizedName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.count <= maximumNameLength,
      trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidName
    }
    return trimmed
  }
}

struct MacVirtualMachineDiskSnapshotConfiguration:
  Codable,
  Equatable,
  Sendable
{
  static let maximumSnapshotCount = 8
  static let empty = MacVirtualMachineDiskSnapshotConfiguration(
    uncheckedRevision: 0,
    layers: [],
    snapshots: []
  )

  let revision: UInt64
  let layers: [MacVirtualMachineDiskSnapshotLayer]
  let snapshots: [MacVirtualMachineDiskSnapshot]

  init(
    revision: UInt64 = 0,
    layers: [MacVirtualMachineDiskSnapshotLayer] = [],
    snapshots: [MacVirtualMachineDiskSnapshot] = []
  ) throws {
    try Self.validate(layers: layers, snapshots: snapshots)
    self.revision = revision
    self.layers = layers
    self.snapshots = snapshots
  }

  private init(
    uncheckedRevision revision: UInt64,
    layers: [MacVirtualMachineDiskSnapshotLayer],
    snapshots: [MacVirtualMachineDiskSnapshot]
  ) {
    self.revision = revision
    self.layers = layers
    self.snapshots = snapshots
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revision: container.decode(UInt64.self, forKey: .revision),
      layers: container.decode(
        [MacVirtualMachineDiskSnapshotLayer].self,
        forKey: .layers
      ),
      snapshots: container.decode(
        [MacVirtualMachineDiskSnapshot].self,
        forKey: .snapshots
      )
    )
  }

  var activeLayer: MacVirtualMachineDiskSnapshotLayer? {
    layers.last
  }

  var hasSnapshots: Bool {
    !snapshots.isEmpty
  }

  func creatingSnapshot(
    named name: String,
    snapshotID: UUID = UUID(),
    layerID: UUID = UUID(),
    at date: Date = Date()
  ) throws -> MacVirtualMachineDiskSnapshotMutation {
    guard revision < UInt64.max else {
      throw MacVirtualMachineDiskSnapshotError.configurationRevisionOverflow
    }
    guard snapshots.count < Self.maximumSnapshotCount else {
      throw MacVirtualMachineDiskSnapshotError.maximumSnapshotCount(
        Self.maximumSnapshotCount
      )
    }

    let normalizedName = try MacVirtualMachineDiskSnapshot.normalizedName(name)
    guard !snapshots.contains(where: {
      $0.name.compare(
        normalizedName,
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      ) == .orderedSame
    }) else {
      throw MacVirtualMachineDiskSnapshotError.duplicateName(normalizedName)
    }

    let snapshot = try MacVirtualMachineDiskSnapshot(
      id: snapshotID,
      name: normalizedName,
      createdAt: date,
      capturedLayerCount: layers.count
    )
    let layer = MacVirtualMachineDiskSnapshotLayer(
      id: layerID,
      createdAt: date
    )
    let configuration = try Self(
      revision: revision + 1,
      layers: layers + [layer],
      snapshots: snapshots + [snapshot]
    )
    return MacVirtualMachineDiskSnapshotMutation(
      configuration: configuration,
      createdLayer: layer,
      retiredLayers: []
    )
  }

  func restoring(
    snapshotID: UUID,
    layerID: UUID = UUID(),
    at date: Date = Date()
  ) throws -> MacVirtualMachineDiskSnapshotMutation {
    guard revision < UInt64.max else {
      throw MacVirtualMachineDiskSnapshotError.configurationRevisionOverflow
    }
    guard let index = snapshots.firstIndex(where: { $0.id == snapshotID }) else {
      throw MacVirtualMachineDiskSnapshotError.snapshotNotFound(snapshotID)
    }

    let snapshot = snapshots[index]
    let retainedLayers = Array(layers.prefix(snapshot.capturedLayerCount))
    let retiredLayers = Array(layers.dropFirst(snapshot.capturedLayerCount))
    let retainedSnapshots = Array(snapshots.prefix(index + 1))
    let layer = MacVirtualMachineDiskSnapshotLayer(
      id: layerID,
      createdAt: date
    )
    let configuration = try Self(
      revision: revision + 1,
      layers: retainedLayers + [layer],
      snapshots: retainedSnapshots
    )
    return MacVirtualMachineDiskSnapshotMutation(
      configuration: configuration,
      createdLayer: layer,
      retiredLayers: retiredLayers
    )
  }

  private static func validate(
    layers: [MacVirtualMachineDiskSnapshotLayer],
    snapshots: [MacVirtualMachineDiskSnapshot]
  ) throws {
    guard layers.count == snapshots.count,
      layers.count <= maximumSnapshotCount
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot and layer counts must match within the supported limit"
      )
    }
    guard Set(layers.map(\.id)).count == layers.count,
      Set(layers.map(\.relativePath)).count == layers.count,
      layers.allSatisfy(\.isCanonical)
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot layers must have unique canonical paths"
      )
    }
    guard Set(snapshots.map(\.id)).count == snapshots.count,
      snapshots.enumerated().allSatisfy({
        $0.element.capturedLayerCount == $0.offset
      })
    else {
      throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot history is not a linear layer stack"
      )
    }

    var normalizedNames = Set<String>()
    for snapshot in snapshots {
      let normalized = try MacVirtualMachineDiskSnapshot.normalizedName(snapshot.name)
        .folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      guard normalizedNames.insert(normalized).inserted else {
        throw MacVirtualMachineDiskSnapshotError.invalidConfiguration(
          "snapshot names must be unique"
        )
      }
    }
  }
}

struct MacVirtualMachineDiskSnapshotMutation: Equatable, Sendable {
  let configuration: MacVirtualMachineDiskSnapshotConfiguration
  let createdLayer: MacVirtualMachineDiskSnapshotLayer
  let retiredLayers: [MacVirtualMachineDiskSnapshotLayer]
}

enum MacVirtualMachineDiskSnapshotError:
  LocalizedError,
  Equatable,
  Sendable
{
  case unavailable
  case invalidName
  case duplicateName(String)
  case maximumSnapshotCount(Int)
  case snapshotNotFound(UUID)
  case configurationRevisionOverflow
  case invalidConfiguration(String)
  case savedStateMustBeDiscarded
  case layerCreationFailed(String)
  case unsafeArtifact(String)
  case committedCleanupPending(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine disk snapshots require macOS 27 or later."
    case .invalidName:
      "Enter a snapshot name between 1 and \(MacVirtualMachineDiskSnapshot.maximumNameLength) characters."
    case .duplicateName(let name):
      "A snapshot named “\(name)” already exists."
    case .maximumSnapshotCount(let count):
      "This virtual machine has the maximum of \(count) disk snapshots. Restore an earlier snapshot to prune newer history."
    case .snapshotNotFound:
      "The selected disk snapshot no longer exists."
    case .configurationRevisionOverflow:
      "The disk snapshot configuration cannot be changed again."
    case .invalidConfiguration(let reason):
      "The disk snapshot history is invalid: \(reason)"
    case .savedStateMustBeDiscarded:
      "Discard this virtual machine’s saved state before changing disk snapshots."
    case .layerCreationFailed(let reason):
      "The disk snapshot layer could not be created: \(reason)"
    case .unsafeArtifact(let reason):
      "The disk snapshot operation stopped because an artifact was unsafe: \(reason)"
    case .committedCleanupPending(let reason):
      "The snapshot was restored, but newer layer cleanup is pending: \(reason)"
    }
  }
}
