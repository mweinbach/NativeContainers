import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import Testing

@testable import NativeContainers

@Suite("Apple Linux machine configuration service")
struct AppleLinuxMachineConfigurationServiceTests {
  @Test
  func updatesStoppedMachineAndVerifiesThePersistedConfiguration() async throws {
    let source = stoppedSnapshot(try makeMachineSnapshot(initialized: true))
    let transport = ConfigurationMachineTransport(
      snapshot: source,
      behavior: .commit
    )
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: transport,
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try configurationRequest()

    let result = try await service.updateConfiguration(
      for: AppleLinuxMachineSnapshotMapper.identity(from: source),
      request: request
    )

    #expect(result.configuration == request.configuration)
    #expect(result.state == .stopped)
    #expect(!result.requiresRestart)
    #expect(await transport.setIDs == ["dev"])
    let sent = try #require(await transport.sentBootConfigs.first)
    #expect(
      try AppleLinuxMachineSnapshotMapper.configuration(
        from: replacingBootConfig(source, with: sent)) == request.configuration)
  }

  @Test
  func reportsThatAStartedMachineRequiresRestart() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: ConfigurationMachineTransport(
        snapshot: source,
        behavior: .commit
      ),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    let result = try await service.updateConfiguration(
      for: AppleLinuxMachineSnapshotMapper.identity(from: source),
      request: try configurationRequest()
    )

    #expect(result.state == .running)
    #expect(result.requiresRestart)
  }

  @Test
  func refusesStaleAndUnstableIdentitiesBeforeMutation() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let transport = ConfigurationMachineTransport(snapshot: source, behavior: .commit)
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: transport,
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try configurationRequest()
    let identity = AppleLinuxMachineSnapshotMapper.identity(from: source)

    let stale = LinuxMachineIdentity(
      id: identity.id,
      imageReference: identity.imageReference,
      platform: identity.platform,
      createdAt: Date(timeIntervalSince1970: 99)
    )
    await #expect(throws: LinuxMachineConfigurationError.staleTarget("dev")) {
      try await service.updateConfiguration(for: stale, request: request)
    }

    let unstable = LinuxMachineIdentity(
      id: identity.id,
      imageReference: identity.imageReference,
      platform: identity.platform,
      createdAt: nil
    )
    await #expect(throws: LinuxMachineConfigurationError.stableIdentityRequired("dev")) {
      try await service.updateConfiguration(for: unstable, request: request)
    }
    #expect(await transport.setIDs.isEmpty)
  }

  @Test
  func reconcilesACommittedConfigurationAfterCancellation() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: ConfigurationMachineTransport(
        snapshot: source,
        behavior: .commitThenCancel
      ),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let request = try configurationRequest()

    let result = try await service.updateConfiguration(
      for: AppleLinuxMachineSnapshotMapper.identity(from: source),
      request: request
    )

    #expect(result.configuration == request.configuration)
  }

  @Test
  func reportsUnknownOutcomeWhenFailureCannotBeReconciled() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: ConfigurationMachineTransport(
        snapshot: source,
        behavior: .failThenDisableVerification
      ),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    do {
      _ = try await service.updateConfiguration(
        for: AppleLinuxMachineSnapshotMapper.identity(from: source),
        request: try configurationRequest()
      )
      #expect(Bool(false), "Expected an unknown configuration outcome.")
    } catch let error as LinuxMachineConfigurationError {
      guard case .updateOutcomeUnknown(let id, _, _) = error else {
        #expect(Bool(false), "Expected updateOutcomeUnknown, received \(error).")
        return
      }
      #expect(id == "dev")
    }
  }

  @Test
  func rejectsAReplyThatDoesNotPersistTheRequestedConfiguration() async throws {
    let source = try makeMachineSnapshot(initialized: true)
    let service = AppleLinuxMachineConfigurationService(
      machineTransport: ConfigurationMachineTransport(
        snapshot: source,
        behavior: .replyWithoutCommit
      ),
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )

    await #expect(throws: LinuxMachineConfigurationError.updateNotConfirmed("dev")) {
      try await service.updateConfiguration(
        for: AppleLinuxMachineSnapshotMapper.identity(from: source),
        request: try configurationRequest()
      )
    }
  }

  @Test
  func writableHomeMountRequiresExplicitAuthorization() {
    #expect(throws: LinuxMachineValidationError.writableHomeMountRequiresAuthorization) {
      try LinuxMachineConfigurationUpdateRequest(
        cpuCount: 4,
        memoryBytes: 4 * 1_024 * LinuxMachineConfiguration.bytesPerMiB,
        homeMount: .readWrite,
        allowsWritableHomeMount: false
      )
    }
  }
}

private enum ConfigurationTransportBehavior: Sendable {
  case commit
  case commitThenCancel
  case replyWithoutCommit
  case failThenDisableVerification
}

private enum ConfigurationTransportError: Error {
  case requestFailed
  case verificationFailed
  case unsupported
}

private actor ConfigurationMachineTransport: AppleMachineTransport {
  private var snapshot: MachineSnapshot
  private let behavior: ConfigurationTransportBehavior
  private var verificationIsDisabled = false

  private(set) var setIDs: [String] = []
  private(set) var sentBootConfigs: [MachineConfig] = []

  init(
    snapshot: MachineSnapshot,
    behavior: ConfigurationTransportBehavior
  ) {
    self.snapshot = snapshot
    self.behavior = behavior
  }

  func list() throws -> [MachineSnapshot] {
    guard !verificationIsDisabled else {
      throw ConfigurationTransportError.verificationFailed
    }
    return [snapshot]
  }

  func inspect(id: String) throws -> MachineSnapshot {
    guard !verificationIsDisabled else {
      throw ConfigurationTransportError.verificationFailed
    }
    return snapshot
  }

  func setConfig(id: String, bootConfig: MachineConfig) throws {
    setIDs.append(id)
    sentBootConfigs.append(bootConfig)

    switch behavior {
    case .commit:
      snapshot = replacingBootConfig(snapshot, with: bootConfig)
    case .commitThenCancel:
      snapshot = replacingBootConfig(snapshot, with: bootConfig)
      throw CancellationError()
    case .replyWithoutCommit:
      break
    case .failThenDisableVerification:
      verificationIsDisabled = true
      throw ConfigurationTransportError.requestFailed
    }
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) throws {
    throw ConfigurationTransportError.unsupported
  }

  func boot(
    id: String,
    dynamicEnvironment: [String: String]
  ) throws -> MachineSnapshot {
    throw ConfigurationTransportError.unsupported
  }

  func stop(id: String) throws {
    throw ConfigurationTransportError.unsupported
  }

  func delete(id: String) throws {
    throw ConfigurationTransportError.unsupported
  }
}

private func configurationRequest() throws -> LinuxMachineConfigurationUpdateRequest {
  try LinuxMachineConfigurationUpdateRequest(
    cpuCount: 6,
    memoryBytes: 4 * 1_024 * LinuxMachineConfiguration.bytesPerMiB,
    homeMount: .readOnly,
    allowsWritableHomeMount: false
  )
}

private func replacingBootConfig(
  _ source: MachineSnapshot,
  with bootConfig: MachineConfig
) -> MachineSnapshot {
  MachineSnapshot(
    configuration: source.configuration,
    status: source.status,
    bootConfig: bootConfig,
    startedDate: source.startedDate,
    createdDate: source.createdDate,
    containerId: source.containerId,
    ipAddress: source.ipAddress,
    diskSize: source.diskSize,
    initialized: source.initialized
  )
}

private func stoppedSnapshot(_ source: MachineSnapshot) -> MachineSnapshot {
  MachineSnapshot(
    configuration: source.configuration,
    status: .stopped,
    bootConfig: source.bootConfig,
    createdDate: source.createdDate,
    diskSize: source.diskSize,
    initialized: source.initialized
  )
}
