import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Testing

@testable import NativeContainers

@Suite("Linux machine inventory service")
struct AppleLinuxMachineInventoryServiceTests {
  @Test
  func refreshesUninitializedListSnapshotBeforePublishing() async throws {
    let listed = try makeMachineSnapshot(initialized: false)
    let refreshed = try makeMachineSnapshot(initialized: true)
    let transport = MachineInventoryTransportDouble(
      listed: [listed],
      inspected: refreshed
    )
    let service = AppleLinuxMachineInventoryService(machineTransport: transport)

    let machines = try await service.loadMachines()

    #expect(machines.map(\.isInitialized) == [true])
    #expect(machines.map(\.cpuCount) == [refreshed.bootConfig.cpus])
    #expect(machines.map(\.memoryBytes) == [refreshed.bootConfig.memory.toUInt64(unit: .bytes)])
    #expect(machines.map(\.homeMount) == [.none])
    #expect(await transport.inspectCalls == ["dev"])
  }

  @Test
  func keepsListedMachineVisibleWhenRefreshFails() async throws {
    let listed = try makeMachineSnapshot(initialized: false)
    let transport = MachineInventoryTransportDouble(
      listed: [listed],
      inspected: nil
    )
    let service = AppleLinuxMachineInventoryService(machineTransport: transport)

    let machines = try await service.loadMachines()

    #expect(machines.map(\.id) == ["dev"])
    #expect(machines.map(\.isInitialized) == [false])
  }

  @Test
  func skipsInspectionForAlreadyInitializedSnapshot() async throws {
    let listed = try makeMachineSnapshot(initialized: true)
    let transport = MachineInventoryTransportDouble(
      listed: [listed],
      inspected: nil
    )
    let service = AppleLinuxMachineInventoryService(machineTransport: transport)

    let machines = try await service.loadMachines()

    #expect(machines.map(\.isInitialized) == [true])
    #expect(await transport.inspectCalls.isEmpty)
  }
}

private enum MachineInventoryTransportError: Error {
  case unavailable
  case unsupported
}

private actor MachineInventoryTransportDouble: AppleMachineTransport {
  private let listed: [MachineSnapshot]
  private let inspected: MachineSnapshot?
  private(set) var inspectCalls: [String] = []

  init(listed: [MachineSnapshot], inspected: MachineSnapshot?) {
    self.listed = listed
    self.inspected = inspected
  }

  func list() -> [MachineSnapshot] {
    listed
  }

  func inspect(id: String) throws -> MachineSnapshot {
    inspectCalls.append(id)
    guard let inspected else {
      throw MachineInventoryTransportError.unavailable
    }
    return inspected
  }

  func create(
    configuration: MachineConfiguration,
    resources: MachineResources?,
    bootConfig: MachineConfig
  ) throws {
    throw MachineInventoryTransportError.unsupported
  }

  func boot(
    id: String,
    dynamicEnvironment: [String: String]
  ) throws -> MachineSnapshot {
    throw MachineInventoryTransportError.unsupported
  }

  func setConfig(id: String, bootConfig: MachineConfig) throws {
    throw MachineInventoryTransportError.unsupported
  }

  func stop(id: String) throws {
    throw MachineInventoryTransportError.unsupported
  }

  func delete(id: String) throws {
    throw MachineInventoryTransportError.unsupported
  }
}

func makeMachineSnapshot(initialized: Bool) throws -> MachineSnapshot {
  let descriptor = Descriptor(
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: "sha256:" + String(repeating: "a", count: 64),
    size: 1
  )
  let configuration = try MachineConfiguration(
    id: "dev",
    image: ImageDescription(reference: "alpine:3.22", descriptor: descriptor),
    platform: Platform(arch: "arm64", os: "linux", variant: nil),
    userSetup: UserSetup(username: "developer", uid: 501, gid: 20)
  )
  let bootConfig = try MachineConfig(
    cpus: 4,
    memory: MemorySize("2gb"),
    homeMount: .some(MachineConfig.HomeMountOption.none)
  )
  return MachineSnapshot(
    configuration: configuration,
    status: .running,
    bootConfig: bootConfig,
    startedDate: Date(timeIntervalSince1970: 2),
    createdDate: Date(timeIntervalSince1970: 1),
    containerId: "dev-runtime",
    ipAddress: "192.0.2.2",
    diskSize: 4_294_967_296,
    initialized: initialized
  )
}
