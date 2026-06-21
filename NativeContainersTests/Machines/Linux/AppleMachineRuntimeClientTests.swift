import ContainerPersistence
import ContainerResource
import Foundation
import MachineAPIClient
import TerminalProgress
import Testing

@testable import NativeContainers

@Suite("Apple machine runtime client")
struct AppleMachineRuntimeClientTests {
  @Test
  func delegatesCreationPreparationAndTransportThroughFocusedServices() async throws {
    let source = try makeMachineSnapshot(initialized: false)
    let stopped = MachineSnapshot(
      configuration: source.configuration,
      status: .stopped,
      bootConfig: source.bootConfig,
      createdDate: source.createdDate,
      diskSize: source.diskSize,
      initialized: false
    )
    let preparation = MachinePreparationDouble(
      prepared: PreparedLinuxMachineCreation(
        configuration: stopped.configuration,
        resources: nil,
        bootConfig: stopped.bootConfig
      )
    )
    let transport = MachineRuntimeTransportDouble(snapshot: stopped)
    let runtime = AppleMachineRuntimeClient(
      imagePreparation: preparation,
      machineTransport: transport
    )
    let request = try LinuxMachineCreationRequest(
      name: "dev",
      imageReference: "alpine:3.22",
      cpuCount: 4,
      memoryBytes: 2_048 * LinuxMachineCreationRequest.bytesPerMiB,
      homeMount: .none
    )
    let progress = ProgressRecorderForRuntime()

    let created = try await runtime.create(request: request) { update in
      await progress.record(update)
    }

    #expect(created.identity.id == "dev")
    #expect(created.state == .stopped)
    #expect(await preparation.requestNames == ["dev"])
    #expect(await transport.createdIDs == ["dev"])
    #expect(
      await progress.phases == [
        ContainerOperationProgress.Phase.preparing,
        ContainerOperationProgress.Phase.fetchingImage,
        ContainerOperationProgress.Phase.creating,
      ]
    )
  }
}

private enum MachineRuntimeDoubleError: Error {
  case unsupported
}

private actor MachinePreparationDouble: LinuxMachineImagePreparing {
  private let prepared: PreparedLinuxMachineCreation
  private(set) var requestNames: [String] = []

  init(prepared: PreparedLinuxMachineCreation) {
    self.prepared = prepared
  }

  func prepare(
    request: LinuxMachineCreationRequest,
    progressUpdate: @escaping ProgressUpdateHandler
  ) async -> PreparedLinuxMachineCreation {
    requestNames.append(request.name)
    await progressUpdate([.setDescription("Fetching image")])
    return prepared
  }
}

private actor MachineRuntimeTransportDouble: AppleMachineTransport {
  private let snapshot: MachineSnapshot
  private(set) var createdIDs: [String] = []

  init(snapshot: MachineSnapshot) {
    self.snapshot = snapshot
  }

  func list() -> [MachineSnapshot] {
    [snapshot]
  }

  func inspect(id: String) -> MachineSnapshot {
    snapshot
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) {
    createdIDs.append(configuration.id)
  }

  func boot(
    id: String,
    dynamicEnvironment: [String: String]
  ) throws -> MachineSnapshot {
    throw MachineRuntimeDoubleError.unsupported
  }

  func setConfig(id: String, bootConfig: MachineConfig) throws {
    throw MachineRuntimeDoubleError.unsupported
  }

  func stop(id: String) throws {
    throw MachineRuntimeDoubleError.unsupported
  }

  func delete(id: String) throws {
    throw MachineRuntimeDoubleError.unsupported
  }
}

private actor ProgressRecorderForRuntime {
  private(set) var phases: [ContainerOperationProgress.Phase] = []

  func record(_ progress: ContainerOperationProgress) {
    phases.append(progress.phase)
  }
}
