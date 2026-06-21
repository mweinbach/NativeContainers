import Foundation

enum ResourceOperationLabel {
  static let key = "com.nativecontainers.resource-operation"
  static let applePluginKey = "com.apple.container.plugin"
  static let appleResourceRoleKey = "com.apple.container.resource.role"
}

enum VolumeJournalMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case ordered
  case writeback
  case journal

  var id: Self { self }

  var title: String {
    switch self {
    case .ordered: "Ordered"
    case .writeback: "Writeback"
    case .journal: "Journal"
    }
  }
}

struct VolumeCreateRequest: Equatable, Sendable {
  static let bytesPerMiB: UInt64 = 1_048_576
  static let maximumSizeBytes: UInt64 = 2 * 1_024 * 1_024 * bytesPerMiB
  static let defaultSizeBytes: UInt64 = 64 * 1_024 * bytesPerMiB

  let operationID: UUID
  let name: String
  let sizeBytes: UInt64
  let journalMode: VolumeJournalMode
  let labels: [String: String]

  init(
    operationID: UUID = UUID(),
    name: String,
    sizeBytes: UInt64 = Self.defaultSizeBytes,
    journalMode: VolumeJournalMode = .ordered,
    labels: [String: String] = [:]
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      name.count <= 255,
      name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#,
        options: .regularExpression
      ) != nil
    else {
      throw ResourceManagementError.invalidVolumeName
    }
    guard
      sizeBytes >= Self.bytesPerMiB,
      sizeBytes <= Self.maximumSizeBytes,
      sizeBytes.isMultiple(of: Self.bytesPerMiB)
    else {
      throw ResourceManagementError.invalidVolumeSize
    }
    guard labels[ResourceOperationLabel.key] == nil else {
      throw ResourceManagementError.reservedMetadataKey(ResourceOperationLabel.key)
    }

    self.operationID = operationID
    self.name = name
    self.sizeBytes = sizeBytes
    self.journalMode = journalMode
    self.labels = labels
  }
}

struct VolumeConfigurationIdentity: Codable, Equatable, Sendable {
  let name: String
  let driver: String
  let format: String
  let source: String
  let createdAt: Date
  let labels: [String: String]
  let options: [String: String]
  let sizeBytes: UInt64?
}

struct VolumeCreationPlan: Equatable, Sendable {
  let request: VolumeCreateRequest
  let generatedAt: Date
}

struct VolumeDeletionPlan: Equatable, Sendable {
  let volume: VolumeRecord
  let identity: VolumeConfigurationIdentity
  let generatedAt: Date

  var canDelete: Bool { volume.usedByContainerIDs.isEmpty }
}

struct VolumePrunePlan: Equatable, Sendable {
  let candidates: [VolumeDeletionPlan]
  let generatedAt: Date

  var estimatedReclaimableBytes: UInt64 {
    candidates.reduce(0) { partial, plan in
      let (sum, overflow) = partial.addingReportingOverflow(plan.volume.allocatedBytes ?? 0)
      return overflow ? UInt64.max : sum
    }
  }
}

enum ContainerNetworkMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case nat
  case hostOnly

  var id: Self { self }

  var title: String {
    switch self {
    case .nat: "NAT"
    case .hostOnly: "Host only"
    }
  }
}

struct NetworkCreateRequest: Equatable, Sendable {
  let operationID: UUID
  let name: String
  let mode: ContainerNetworkMode
  let ipv4Subnet: String?
  let ipv6Subnet: String?
  let labels: [String: String]

  init(
    operationID: UUID = UUID(),
    name: String,
    mode: ContainerNetworkMode = .nat,
    ipv4Subnet: String? = nil,
    ipv6Subnet: String? = nil,
    labels: [String: String] = [:]
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      name.range(
        of: #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#,
        options: .regularExpression
      ) != nil
    else {
      throw ResourceManagementError.invalidNetworkName
    }
    for reservedKey in [
      ResourceOperationLabel.key,
      ResourceOperationLabel.appleResourceRoleKey,
    ] where labels[reservedKey] != nil {
      throw ResourceManagementError.reservedMetadataKey(reservedKey)
    }

    self.operationID = operationID
    self.name = name
    self.mode = mode
    self.ipv4Subnet = Self.trimmedOptional(ipv4Subnet)
    self.ipv6Subnet = Self.trimmedOptional(ipv6Subnet)
    self.labels = labels
  }

  private static func trimmedOptional(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.flatMap { $0.isEmpty ? nil : $0 }
  }
}

struct NetworkConfigurationIdentity: Codable, Equatable, Sendable {
  let name: String
  let mode: ContainerNetworkMode
  let createdAt: Date
  let configuredIPv4Subnet: String?
  let configuredIPv6Subnet: String?
  let labels: [String: String]
  let plugin: String
  let options: [String: String]
  let isBuiltin: Bool
}

struct NetworkRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let name: String
  let mode: ContainerNetworkMode
  let createdAt: Date
  let configuredIPv4Subnet: String?
  let configuredIPv6Subnet: String?
  let assignedIPv4Subnet: String
  let ipv4Gateway: String
  let assignedIPv6Subnet: String?
  let labels: [String: String]
  let plugin: String
  let options: [String: String]
  let isBuiltin: Bool
  let usedByContainerIDs: [String]

  var configurationIdentity: NetworkConfigurationIdentity {
    NetworkConfigurationIdentity(
      name: name,
      mode: mode,
      createdAt: createdAt,
      configuredIPv4Subnet: configuredIPv4Subnet,
      configuredIPv6Subnet: configuredIPv6Subnet,
      labels: labels,
      plugin: plugin,
      options: options,
      isBuiltin: isBuiltin
    )
  }
}

struct NetworkCreationPlan: Equatable, Sendable {
  let request: NetworkCreateRequest
  let generatedAt: Date
}

struct NetworkDeletionPlan: Equatable, Sendable {
  let network: NetworkRecord
  let identity: NetworkConfigurationIdentity
  let generatedAt: Date

  var canDelete: Bool {
    !network.isBuiltin && network.usedByContainerIDs.isEmpty
  }
}

struct NetworkPrunePlan: Equatable, Sendable {
  let candidates: [NetworkDeletionPlan]
  let generatedAt: Date
}

struct ResourceOperationFailure: Equatable, Sendable, Identifiable {
  let resource: String
  let message: String

  var id: String { resource }
}

struct ResourceCleanupResult: Equatable, Sendable {
  let removedResourceNames: [String]
  let failedResources: [ResourceOperationFailure]
  let reclaimedBytes: UInt64

  var completedWithoutFailures: Bool { failedResources.isEmpty }
}

struct ResourceCleanupPartialCompletionError: LocalizedError, Sendable {
  let operation: String
  let result: ResourceCleanupResult

  var errorDescription: String? {
    let removed = result.removedResourceNames.count
    let remaining = result.failedResources.count
    return
      "\(operation) was cancelled after removing \(removed) resource(s); \(remaining) reviewed resource(s) remain."
  }
}

enum ContainerBrowserScheme: String, CaseIterable, Identifiable, Sendable {
  case http
  case https

  var id: Self { self }

  var title: String { rawValue.uppercased() }
}

struct ContainerBrowserTarget: Equatable, Sendable {
  let containerID: String
  let containerCreatedAt: Date
  let portID: ContainerPort.ID
  let scheme: ContainerBrowserScheme
}

enum ContainerBrowserURLBuilder {
  static func makeURL(
    port: ContainerPort,
    scheme: ContainerBrowserScheme
  ) throws -> URL {
    guard port.protocolName.lowercased() == ContainerTransportProtocol.tcp.rawValue else {
      throw ResourceManagementError.browserRequiresTCP
    }

    let host = browserHost(port.hostAddress)
    guard !host.isEmpty, !host.contains("/"), !host.contains(where: \.isWhitespace) else {
      throw ResourceManagementError.invalidBrowserHost(port.hostAddress)
    }

    var components: URLComponents
    if host.contains(":") {
      guard
        let parsed = URLComponents(string: "\(scheme.rawValue)://[\(host)]"),
        parsed.host == host || parsed.host == "[\(host)]"
      else {
        throw ResourceManagementError.invalidBrowserHost(port.hostAddress)
      }
      components = parsed
    } else {
      components = URLComponents()
      components.scheme = scheme.rawValue
      components.host = host
    }
    let isDefaultPort =
      (scheme == .http && port.hostPort == 80)
      || (scheme == .https && port.hostPort == 443)
    if !isDefaultPort {
      components.port = Int(port.hostPort)
    }
    components.path = "/"
    guard let url = components.url else {
      throw ResourceManagementError.invalidBrowserHost(port.hostAddress)
    }
    return url
  }

  private static func browserHost(_ value: String) -> String {
    let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch host {
    case "*", "0.0.0.0":
      return "127.0.0.1"
    case "::", "[::]":
      return "::1"
    default:
      if host.hasPrefix("["), host.hasSuffix("]") {
        return String(host.dropFirst().dropLast())
      }
      return host
    }
  }
}

enum ResourceMetadataParser {
  static func parse(_ text: String) throws -> [String: String] {
    var values: [String: String] = [:]
    for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let separator = line.firstIndex(of: "=") else {
        throw ResourceManagementError.invalidMetadataLine(offset + 1)
      }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty else {
        throw ResourceManagementError.invalidMetadataLine(offset + 1)
      }
      guard values[String(key)] == nil else {
        throw ResourceManagementError.duplicateMetadataKey(String(key))
      }
      values[String(key)] = String(value)
    }
    return values
  }
}

enum InfrastructureExecutionSafety {
  static func validateVolumeDeletion(
    plan: VolumeDeletionPlan,
    current: VolumeRecord
  ) throws {
    guard
      current.id == plan.volume.id,
      current.configurationIdentity == plan.identity
    else {
      throw ResourceManagementError.stalePlan(plan.volume.name)
    }
    guard current.usedByContainerIDs.isEmpty else {
      throw ResourceManagementError.volumeInUse(
        name: current.name,
        containerIDs: current.usedByContainerIDs
      )
    }
  }

  static func validateNetworkDeletion(
    plan: NetworkDeletionPlan,
    current: NetworkRecord
  ) throws {
    guard current.configurationIdentity == plan.identity else {
      throw ResourceManagementError.stalePlan(plan.network.name)
    }
    guard !current.isBuiltin else {
      throw ResourceManagementError.builtinNetwork(current.name)
    }
    guard current.usedByContainerIDs.isEmpty else {
      throw ResourceManagementError.networkInUse(
        name: current.name,
        containerIDs: current.usedByContainerIDs
      )
    }
  }
}

enum ResourceManagementError: LocalizedError, Equatable, Sendable {
  case unsupported
  case invalidVolumeName
  case invalidVolumeSize
  case invalidNetworkName
  case invalidMetadataLine(Int)
  case duplicateMetadataKey(String)
  case reservedMetadataKey(String)
  case volumeInUse(name: String, containerIDs: [String])
  case networkInUse(name: String, containerIDs: [String])
  case builtinNetwork(String)
  case stalePlan(String)
  case resourceAlreadyExists(String)
  case browserRequiresTCP
  case containerNotRunning(String)
  case containerReplaced(String)
  case publishedPortChanged
  case invalidBrowserHost(String)
  case operationTimedOut(String)
  case invalidInfrastructureResponse
  case cleanupStateUnknown(String)
  case ownedResourceCleanupFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "Volume and network management are unavailable from this container service."
    case .invalidVolumeName:
      "Use up to 255 letters, numbers, periods, underscores, or hyphens for the volume name."
    case .invalidVolumeSize:
      "Volume size must be between 1 MiB and 2 TiB in whole MiB increments."
    case .invalidNetworkName:
      "Use a lowercase network name of up to 63 letters, numbers, periods, underscores, or hyphens."
    case .invalidMetadataLine(let line):
      "Metadata line \(line) must use KEY=value format."
    case .duplicateMetadataKey(let key):
      "Metadata key “\(key)” appears more than once."
    case .reservedMetadataKey(let key):
      "Metadata key “\(key)” is reserved for NativeContainers."
    case .volumeInUse(let name, let containerIDs):
      "Volume “\(name)” is attached to: \(containerIDs.formatted())."
    case .networkInUse(let name, let containerIDs):
      "Network “\(name)” is attached to: \(containerIDs.formatted())."
    case .builtinNetwork(let name):
      "Network “\(name)” is managed by Apple’s container runtime and cannot be deleted."
    case .stalePlan(let resource):
      "“\(resource)” changed after it was reviewed. Review the operation again before continuing."
    case .resourceAlreadyExists(let name):
      "A resource named “\(name)” already exists."
    case .browserRequiresTCP:
      "Only published TCP ports can be opened in a web browser."
    case .containerNotRunning(let id):
      "Start container “\(id)” before opening its published port."
    case .containerReplaced(let id):
      "Container “\(id)” was replaced. Refresh before opening its published port."
    case .publishedPortChanged:
      "The published port changed. Refresh the container and try again."
    case .invalidBrowserHost(let host):
      "“\(host)” is not a valid browser host."
    case .operationTimedOut(let operation):
      "\(operation) exceeded its safety timeout. Its XPC connection was closed and runtime state will be reconciled."
    case .invalidInfrastructureResponse:
      "Apple’s container service returned an incomplete infrastructure response."
    case .cleanupStateUnknown(let resource):
      "Cancellation closed the request, but the final state of “\(resource)” could not be verified. Refresh before retrying or deleting it manually."
    case .ownedResourceCleanupFailed(let resource):
      "Cancellation created “\(resource)”, but automatic cleanup could not verify its removal. Refresh and delete it manually."
    }
  }
}
