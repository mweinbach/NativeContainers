import Foundation

struct VirtualMachineDiskSnapshotLayer: Codable, Equatable, Sendable, Identifiable {
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

struct VirtualMachineDiskSnapshot: Codable, Equatable, Sendable, Identifiable {
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
      throw VirtualMachineDiskSnapshotError.invalidName
    }
    return trimmed
  }
}

struct VirtualMachineDiskSnapshotConfiguration:
  Codable,
  Equatable,
  Sendable
{
  static let maximumSnapshotCount = 8
  static let empty = VirtualMachineDiskSnapshotConfiguration(
    uncheckedRevision: 0,
    layers: [],
    snapshots: []
  )

  let revision: UInt64
  let layers: [VirtualMachineDiskSnapshotLayer]
  let snapshots: [VirtualMachineDiskSnapshot]

  init(
    revision: UInt64 = 0,
    layers: [VirtualMachineDiskSnapshotLayer] = [],
    snapshots: [VirtualMachineDiskSnapshot] = []
  ) throws {
    try Self.validate(layers: layers, snapshots: snapshots)
    self.revision = revision
    self.layers = layers
    self.snapshots = snapshots
  }

  private init(
    uncheckedRevision revision: UInt64,
    layers: [VirtualMachineDiskSnapshotLayer],
    snapshots: [VirtualMachineDiskSnapshot]
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
        [VirtualMachineDiskSnapshotLayer].self,
        forKey: .layers
      ),
      snapshots: container.decode(
        [VirtualMachineDiskSnapshot].self,
        forKey: .snapshots
      )
    )
  }

  var activeLayer: VirtualMachineDiskSnapshotLayer? {
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
  ) throws -> VirtualMachineDiskSnapshotMutation {
    guard revision < UInt64.max else {
      throw VirtualMachineDiskSnapshotError.configurationRevisionOverflow
    }
    guard snapshots.count < Self.maximumSnapshotCount else {
      throw VirtualMachineDiskSnapshotError.maximumSnapshotCount(
        Self.maximumSnapshotCount
      )
    }

    let normalizedName = try VirtualMachineDiskSnapshot.normalizedName(name)
    guard
      !snapshots.contains(where: {
        $0.name.compare(
          normalizedName,
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedSame
      })
    else {
      throw VirtualMachineDiskSnapshotError.duplicateName(normalizedName)
    }

    let snapshot = try VirtualMachineDiskSnapshot(
      id: snapshotID,
      name: normalizedName,
      createdAt: date,
      capturedLayerCount: layers.count
    )
    let layer = VirtualMachineDiskSnapshotLayer(
      id: layerID,
      createdAt: date
    )
    let configuration = try Self(
      revision: revision + 1,
      layers: layers + [layer],
      snapshots: snapshots + [snapshot]
    )
    return VirtualMachineDiskSnapshotMutation(
      configuration: configuration,
      createdLayer: layer,
      retiredLayers: []
    )
  }

  func restoring(
    snapshotID: UUID,
    layerID: UUID = UUID(),
    at date: Date = Date()
  ) throws -> VirtualMachineDiskSnapshotMutation {
    guard revision < UInt64.max else {
      throw VirtualMachineDiskSnapshotError.configurationRevisionOverflow
    }
    guard let index = snapshots.firstIndex(where: { $0.id == snapshotID }) else {
      throw VirtualMachineDiskSnapshotError.snapshotNotFound(snapshotID)
    }

    let snapshot = snapshots[index]
    let retainedLayers = Array(layers.prefix(snapshot.capturedLayerCount))
    let retiredLayers = Array(layers.dropFirst(snapshot.capturedLayerCount))
    let retainedSnapshots = Array(snapshots.prefix(index + 1))
    let layer = VirtualMachineDiskSnapshotLayer(
      id: layerID,
      createdAt: date
    )
    let configuration = try Self(
      revision: revision + 1,
      layers: retainedLayers + [layer],
      snapshots: retainedSnapshots
    )
    return VirtualMachineDiskSnapshotMutation(
      configuration: configuration,
      createdLayer: layer,
      retiredLayers: retiredLayers
    )
  }

  private static func validate(
    layers: [VirtualMachineDiskSnapshotLayer],
    snapshots: [VirtualMachineDiskSnapshot]
  ) throws {
    guard layers.count == snapshots.count,
      layers.count <= maximumSnapshotCount
    else {
      throw VirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot and layer counts must match within the supported limit"
      )
    }
    guard Set(layers.map(\.id)).count == layers.count,
      Set(layers.map(\.relativePath)).count == layers.count,
      layers.allSatisfy(\.isCanonical)
    else {
      throw VirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot layers must have unique canonical paths"
      )
    }
    guard Set(snapshots.map(\.id)).count == snapshots.count,
      snapshots.enumerated().allSatisfy({
        $0.element.capturedLayerCount == $0.offset
      })
    else {
      throw VirtualMachineDiskSnapshotError.invalidConfiguration(
        "snapshot history is not a linear layer stack"
      )
    }

    var normalizedNames = Set<String>()
    for snapshot in snapshots {
      let normalized = try VirtualMachineDiskSnapshot.normalizedName(snapshot.name)
        .folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      guard normalizedNames.insert(normalized).inserted else {
        throw VirtualMachineDiskSnapshotError.invalidConfiguration(
          "snapshot names must be unique"
        )
      }
    }
  }
}

struct VirtualMachineDiskSnapshotMutation: Equatable, Sendable {
  let configuration: VirtualMachineDiskSnapshotConfiguration
  let createdLayer: VirtualMachineDiskSnapshotLayer
  let retiredLayers: [VirtualMachineDiskSnapshotLayer]
}

struct VirtualMachineDiskSnapshotOperationResult: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let cleanupWarning: String?

  var configuration: VirtualMachineDiskSnapshotConfiguration {
    manifest.effectiveDiskSnapshotConfiguration
  }
}

enum VirtualMachineDiskSnapshotError:
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
  case operationAndCleanupFailed(operation: String, cleanup: String)
  case committedCleanupPending(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine disk snapshots require macOS 27 or later."
    case .invalidName:
      "Enter a snapshot name between 1 and \(VirtualMachineDiskSnapshot.maximumNameLength) characters."
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
    case .operationAndCleanupFailed(let operation, let cleanup):
      "Disk snapshot creation failed (\(operation)), and its layer cleanup also failed (\(cleanup))."
    case .committedCleanupPending(let reason):
      "The snapshot was restored, but newer layer cleanup is pending: \(reason)"
    }
  }
}

typealias MacVirtualMachineDiskSnapshotLayer = VirtualMachineDiskSnapshotLayer
typealias MacVirtualMachineDiskSnapshot = VirtualMachineDiskSnapshot
typealias MacVirtualMachineDiskSnapshotConfiguration =
  VirtualMachineDiskSnapshotConfiguration
typealias MacVirtualMachineDiskSnapshotMutation =
  VirtualMachineDiskSnapshotMutation
typealias MacVirtualMachineDiskSnapshotOperationResult =
  VirtualMachineDiskSnapshotOperationResult
typealias MacVirtualMachineDiskSnapshotError = VirtualMachineDiskSnapshotError
