import Foundation

struct ContainerCreationDraft {
  static let memoryOptions = [512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]

  var name = ""
  var imageReference = ""
  var architecture = ContainerArchitecture.arm64
  var cpuCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
  var memoryMiB = 1_024
  var argumentsText = ""
  var environmentText = ""
  var workingDirectory = ""
  var publishedPorts: [ContainerPortDraft] = []
  var volumeMounts: [ContainerVolumeMountDraft] = []
  var hostDirectoryMounts: [ContainerHostDirectoryMountDraft] = []
  var networkAttachments: [ContainerNetworkAttachmentDraft]
  var publishedSockets: [ContainerSocketPublicationDraft] = []
  var requiresHostAccess = false
  var selectedHostAccessID: String?
  var startAfterCreation = true
  var removeWhenStopped = false
  var forwardSSHAgent = false
  var readOnlyRootFilesystem = false
  var useInitProcess = true

  init(defaultNetworkID: String? = nil) {
    networkAttachments =
      defaultNetworkID.map {
        [ContainerNetworkAttachmentDraft(networkID: $0)]
      } ?? []
  }

  mutating func ensureDefaultNetwork(from networks: [NetworkRecord]) {
    guard networkAttachments.isEmpty, let builtin = networks.first(where: \.isBuiltin) else {
      return
    }
    networkAttachments = [ContainerNetworkAttachmentDraft(networkID: builtin.id)]
  }

  func makeRequest(
    availableVolumes: [VolumeRecord],
    availableNetworks: [NetworkRecord],
    attachmentEnvironment: ContainerAttachmentEnvironment?,
    hostDirectoryReviewer: any ContainerHostDirectoryReviewing
  ) throws -> ContainerCreationRequest {
    let operationID = UUID()
    let volumeMounts = try volumeMounts.map { draft in
      guard let volume = availableVolumes.first(where: { $0.name == draft.volumeName }) else {
        throw ContainerAttachmentValidationError.unavailableVolume(draft.volumeName)
      }
      return try ContainerVolumeMount(
        volume: volume,
        containerPath: draft.containerPath,
        isReadOnly: draft.isReadOnly
      )
    }
    let networks = try networkAttachments.map { draft in
      guard
        let network = availableNetworks.first(where: { $0.id == draft.networkID })
      else {
        throw ContainerAttachmentValidationError.unavailableNetwork(draft.networkID)
      }
      return ContainerNetworkAttachment(network: network)
    }
    let requiredHostAccess: ContainerHostAccessConfiguration?
    if requiresHostAccess {
      guard
        let selectedHostAccessID,
        let configuration = attachmentEnvironment?.hostAccess.configurations.first(
          where: { $0.id == selectedHostAccessID }
        )
      else {
        throw ContainerAttachmentValidationError.unavailableHostAccess
      }
      requiredHostAccess = configuration
    } else {
      requiredHostAccess = nil
    }

    let attachments = try ContainerAttachmentSelection(
      volumeMounts: volumeMounts,
      hostDirectoryMounts: try hostDirectoryMounts.map { draft in
        try hostDirectoryReviewer.reviewHostDirectory(
          ContainerHostDirectoryReviewRequest(
            sourceURL: draft.sourceURL,
            containerPath: draft.containerPath,
            isReadOnly: draft.isReadOnly
          )
        )
      },
      networks: networks,
      publishedSockets: try publishedSockets.map { try $0.publication() },
      requiredHostAccess: requiredHostAccess
    )

    return try ContainerCreationRequest(
      operationID: operationID,
      name: name,
      imageReference: imageReference,
      architecture: architecture,
      cpuCount: cpuCount,
      memoryBytes: UInt64(memoryMiB) * ContainerCreationRequest.bytesPerMiB,
      arguments: argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty },
      environment: try environmentVariables(),
      workingDirectory: workingDirectory,
      publishedPorts: try publishedPorts.map { try $0.publication() },
      attachments: attachments,
      startAfterCreation: startAfterCreation,
      removeWhenStopped: removeWhenStopped,
      sshAgent: try reviewedSSHAgent(from: attachmentEnvironment),
      readOnlyRootFilesystem: readOnlyRootFilesystem,
      useInitProcess: useInitProcess
    )
  }

  private func environmentVariables() throws -> [ContainerEnvironmentVariable] {
    var result: [ContainerEnvironmentVariable] = []
    for (offset, rawLine) in environmentText.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let separator = line.firstIndex(of: "=") else {
        throw ContainerCreationValidationError.malformedEnvironmentLine(offset + 1)
      }
      result.append(
        try ContainerEnvironmentVariable(
          key: String(line[..<separator]),
          value: String(line[line.index(after: separator)...])
        )
      )
    }
    return result
  }

  private func reviewedSSHAgent(
    from environment: ContainerAttachmentEnvironment?
  ) throws -> ContainerSSHAgentConfiguration? {
    guard forwardSSHAgent else { return nil }
    guard let availability = environment?.sshAgent else {
      throw ContainerSSHAgentError.unavailable(.environmentMissing)
    }
    switch availability {
    case .available(let configuration):
      return configuration
    case .unavailable(let reason):
      throw ContainerSSHAgentError.unavailable(reason)
    }
  }
}

struct ContainerPortDraft: Identifiable {
  let id: UUID
  var hostAddress: String
  var hostPort: Int
  var containerPort: Int
  var transportProtocol: ContainerTransportProtocol

  init(
    id: UUID = UUID(),
    hostAddress: String = "127.0.0.1",
    hostPort: Int = 8_080,
    containerPort: Int = 8_080,
    transportProtocol: ContainerTransportProtocol = .tcp
  ) {
    self.id = id
    self.hostAddress = hostAddress
    self.hostPort = hostPort
    self.containerPort = containerPort
    self.transportProtocol = transportProtocol
  }

  func publication() throws -> ContainerPortPublication {
    guard let hostPort = UInt16(exactly: hostPort),
      let containerPort = UInt16(exactly: containerPort),
      hostPort > 0, containerPort > 0
    else {
      throw ContainerCreationValidationError.invalidPort
    }
    return try ContainerPortPublication(
      hostAddress: hostAddress,
      hostPort: hostPort,
      containerPort: containerPort,
      transportProtocol: transportProtocol
    )
  }
}

struct ContainerVolumeMountDraft: Identifiable {
  let id: UUID
  var volumeName: String
  var containerPath: String
  var isReadOnly: Bool

  init(
    id: UUID = UUID(),
    volumeName: String,
    containerPath: String = "/data",
    isReadOnly: Bool = false
  ) {
    self.id = id
    self.volumeName = volumeName
    self.containerPath = containerPath
    self.isReadOnly = isReadOnly
  }
}

struct ContainerHostDirectoryMountDraft: Identifiable, Equatable {
  let id: UUID
  let sourceURL: URL
  var containerPath: String
  var isReadOnly: Bool

  init(
    id: UUID = UUID(),
    sourceURL: URL,
    containerPath: String? = nil,
    isReadOnly: Bool = true
  ) {
    self.id = id
    self.sourceURL = sourceURL.standardizedFileURL
    self.containerPath = containerPath ?? Self.defaultContainerPath(for: sourceURL)
    self.isReadOnly = isReadOnly
  }

  private static func defaultContainerPath(for sourceURL: URL) -> String {
    let component = sourceURL.lastPathComponent.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        ? String(scalar)
        : "-"
    }.joined()
    let name = component.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "/workspace/\(name.isEmpty ? "shared" : name)"
  }
}

struct ContainerNetworkAttachmentDraft: Identifiable {
  let id: UUID
  var networkID: String

  init(id: UUID = UUID(), networkID: String) {
    self.id = id
    self.networkID = networkID
  }
}

struct ContainerSocketPublicationDraft: Identifiable {
  let id: UUID
  var hostSocketName: String
  var containerPath: String

  init(
    id: UUID = UUID(),
    hostSocketName: String = "service.sock",
    containerPath: String = "/run/service.sock"
  ) {
    self.id = id
    self.hostSocketName = hostSocketName
    self.containerPath = containerPath
  }

  func publication() throws -> ContainerUnixSocketPublication {
    try ContainerUnixSocketPublication(
      hostSocketName: hostSocketName,
      containerPath: containerPath
    )
  }
}
