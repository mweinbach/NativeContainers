import Foundation
import Network

struct ContainerVolumeMount: Equatable, Sendable, Identifiable {
  let volume: VolumeConfigurationIdentity
  let containerPath: String
  let isReadOnly: Bool

  init(
    volume: VolumeRecord,
    containerPath: String,
    isReadOnly: Bool = false
  ) throws {
    guard !volume.isAnonymous else {
      throw ContainerAttachmentValidationError.anonymousVolume(volume.name)
    }

    self.volume = volume.configurationIdentity
    self.containerPath = try ContainerAttachmentPath.containerPath(containerPath)
    self.isReadOnly = isReadOnly
  }

  var id: String {
    "\(volume.name)@\(containerPath)"
  }
}

struct ContainerNetworkAttachment: Equatable, Sendable, Identifiable {
  let networkID: String
  let network: NetworkConfigurationIdentity

  init(network: NetworkRecord) {
    networkID = network.id
    self.network = network.configurationIdentity
  }

  var id: String { networkID }
}

struct ContainerUnixSocketPublication: Equatable, Sendable, Identifiable {
  let hostSocketName: String
  let containerPath: String

  init(hostSocketName: String, containerPath: String) throws {
    let hostSocketName = hostSocketName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      hostSocketName.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\.sock$"#,
        options: .regularExpression
      ) != nil
    else {
      throw ContainerAttachmentValidationError.invalidHostSocketName
    }

    let containerPath = try ContainerAttachmentPath.containerPath(containerPath)
    guard containerPath.utf8.count < 108 else {
      throw ContainerAttachmentValidationError.containerSocketPathTooLong
    }

    self.hostSocketName = hostSocketName
    self.containerPath = containerPath
  }

  var id: String {
    "\(hostSocketName)->\(containerPath)"
  }
}

struct ContainerHostAccessConfiguration: Equatable, Sendable, Identifiable {
  let domain: String
  let redirectIPv4Address: String

  init(domain: String, redirectIPv4Address: String) throws {
    var domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while domain.hasSuffix(".") {
      domain.removeLast()
    }
    guard Self.isValidDomain(domain) else {
      throw ContainerAttachmentValidationError.invalidHostAccessDomain
    }

    let redirectIPv4Address = redirectIPv4Address.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard IPv4Address(redirectIPv4Address) != nil else {
      throw ContainerAttachmentValidationError.invalidHostAccessAddress
    }

    self.domain = domain
    self.redirectIPv4Address = redirectIPv4Address
  }

  var id: String {
    "\(domain)@\(redirectIPv4Address)"
  }

  private static func isValidDomain(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 253 else { return false }
    return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
      label in
      guard !label.isEmpty, label.utf8.count <= 63 else { return false }
      return
        label.range(
          of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#,
          options: .regularExpression
        ) != nil
    }
  }
}

struct ContainerHostAccessCatalog: Equatable, Sendable {
  static let setupCommand =
    "sudo container system dns create host.container.internal --localhost 203.0.113.113"

  let configurations: [ContainerHostAccessConfiguration]
  let warnings: [String]

  static let empty = ContainerHostAccessCatalog(configurations: [], warnings: [])
}

struct ContainerAttachmentSelection: Equatable, Sendable {
  static let empty = ContainerAttachmentSelection()

  let volumeMounts: [ContainerVolumeMount]
  let networks: [ContainerNetworkAttachment]
  let publishedSockets: [ContainerUnixSocketPublication]
  let requiredHostAccess: ContainerHostAccessConfiguration?

  init() {
    volumeMounts = []
    networks = []
    publishedSockets = []
    requiredHostAccess = nil
  }

  init(
    volumeMounts: [ContainerVolumeMount],
    networks: [ContainerNetworkAttachment],
    publishedSockets: [ContainerUnixSocketPublication],
    requiredHostAccess: ContainerHostAccessConfiguration?
  ) throws {
    guard Set(volumeMounts.map(\.containerPath)).count == volumeMounts.count else {
      throw ContainerAttachmentValidationError.duplicateMountDestination
    }
    guard Set(networks.map(\.networkID)).count == networks.count else {
      throw ContainerAttachmentValidationError.duplicateNetwork
    }
    guard Set(publishedSockets.map(\.hostSocketName)).count == publishedSockets.count else {
      throw ContainerAttachmentValidationError.duplicateHostSocketPath
    }
    guard Set(publishedSockets.map(\.containerPath)).count == publishedSockets.count else {
      throw ContainerAttachmentValidationError.duplicateContainerSocketPath
    }

    self.volumeMounts = volumeMounts
    self.networks = networks
    self.publishedSockets = publishedSockets
    self.requiredHostAccess = requiredHostAccess
  }
}

enum ContainerAttachmentValidationError: LocalizedError, Equatable {
  case anonymousVolume(String)
  case invalidContainerPath
  case invalidHostSocketName
  case containerSocketPathTooLong
  case duplicateMountDestination
  case duplicateNetwork
  case duplicateHostSocketPath
  case duplicateContainerSocketPath
  case invalidHostAccessDomain
  case invalidHostAccessAddress
  case unavailableVolume(String)
  case unavailableNetwork(String)
  case unavailableHostAccess

  var errorDescription: String? {
    switch self {
    case .anonymousVolume(let name):
      "Anonymous volume “\(name)” cannot be selected as a reusable named volume."
    case .invalidContainerPath:
      "Container paths must be absolute, non-root paths without dot components."
    case .invalidHostSocketName:
      "Host socket names must end in .sock and use only letters, numbers, periods, underscores, or hyphens."
    case .containerSocketPathTooLong:
      "The socket path inside the Linux container is too long."
    case .duplicateMountDestination:
      "Each volume must use a unique path inside the container."
    case .duplicateNetwork:
      "Each network can be attached only once."
    case .duplicateHostSocketPath:
      "Each published socket must use a unique host path."
    case .duplicateContainerSocketPath:
      "Each published socket must use a unique path inside the container."
    case .invalidHostAccessDomain:
      "The host-access domain is invalid."
    case .invalidHostAccessAddress:
      "The host-access redirect must be an IPv4 address."
    case .unavailableVolume(let name):
      "Named volume “\(name)” is no longer available. Refresh and review the selection."
    case .unavailableNetwork(let name):
      "Network “\(name)” is no longer available. Refresh and review the selection."
    case .unavailableHostAccess:
      "The selected host-access configuration is no longer available. Reconfigure it and review the request."
    }
  }
}

private enum ContainerAttachmentPath {
  static func containerPath(_ rawValue: String) throws -> String {
    try normalizedAbsolutePath(
      rawValue,
      error: ContainerAttachmentValidationError.invalidContainerPath
    )
  }

  private static func normalizedAbsolutePath(
    _ rawValue: String,
    error: ContainerAttachmentValidationError
  ) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("/"), !value.contains("\0") else {
      throw error
    }

    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    guard
      !components.isEmpty,
      components.allSatisfy({ $0 != "." && $0 != ".." })
    else {
      throw error
    }

    return "/" + components.joined(separator: "/")
  }
}
