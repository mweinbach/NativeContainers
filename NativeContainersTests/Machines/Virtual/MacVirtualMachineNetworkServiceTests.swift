import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine network service")
@MainActor
struct MacVirtualMachineNetworkServiceTests {
  @Test
  func snapshotReadsPersistedConfigurationWithoutRuntimeOwnership() async throws {
    let fixture = try NetworkServiceFixture(
      configuration: MacVirtualMachineNetworkConfiguration(
        revision: 3,
        attachment: .hostOnly
      )
    )

    let snapshot = try await fixture.service.snapshot(
      id: fixture.machine.manifest.id
    )

    #expect(snapshot.configuration.revision == 3)
    #expect(snapshot.configuration.attachment == .hostOnly)
    #expect(await fixture.leaseStore.acquireCount == 0)
  }

  @Test
  func mutationPersistsUnderTheRuntimeLeaseAndReleasesIt() async throws {
    let fixture = try NetworkServiceFixture()

    let snapshot = try await fixture.service.setAttachment(
      .shared,
      for: fixture.machine.manifest.id
    )

    #expect(snapshot.configuration.revision == 1)
    #expect(snapshot.configuration.attachment == .shared)
    #expect(await fixture.persistence.setCount == 1)
    #expect(await fixture.leaseStore.acquireCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func savedStateBlocksMutationAndStillReleasesRuntimeOwnership() async throws {
    let fixture = try NetworkServiceFixture(
      savedStateStatus: .incompatible("old network topology")
    )

    await #expect(
      throws: MacVirtualMachineNetworkError.savedStateBlocksChanges(
        fixture.machine.manifest.id
      )
    ) {
      _ = try await fixture.service.setAttachment(
        .hostOnly,
        for: fixture.machine.manifest.id
      )
    }

    #expect(await fixture.persistence.setCount == 0)
    #expect(fixture.releaseRecorder.count == 1)
  }
}

@MainActor
private struct NetworkServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let persistence: NetworkConfigurationPersistence
  let leaseStore: NetworkLeaseStore
  let releaseRecorder = NetworkLeaseReleaseRecorder()
  let service: MacVirtualMachineNetworkService

  init(
    configuration: MacVirtualMachineNetworkConfiguration = .nat,
    savedStateStatus: MacVirtualMachineSavedStateStatus = .none
  ) throws {
    machine = try makeNetworkServiceMachine(configuration: configuration)
    persistence = NetworkConfigurationPersistence(
      configuration: configuration
    )
    leaseStore = NetworkLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    service = MacVirtualMachineNetworkService(
      leasingStore: leaseStore,
      persistence: persistence,
      savedStateService: NetworkSavedStateService(
        status: savedStateStatus
      )
    )
  }
}

private actor NetworkConfigurationPersistence:
  MacVirtualMachineNetworkConfigurationPersisting
{
  private var configuration: MacVirtualMachineNetworkConfiguration
  private(set) var setCount = 0

  init(configuration: MacVirtualMachineNetworkConfiguration) {
    self.configuration = configuration
  }

  func macOSNetworkConfiguration(
    id: UUID
  ) -> MacVirtualMachineNetworkConfiguration {
    configuration
  }

  func setMacOSNetworkAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineNetworkConfiguration {
    setCount += 1
    configuration = try configuration.settingAttachment(attachment)
    return configuration
  }
}

private actor NetworkLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: NetworkLeaseReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: NetworkLeaseReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireMacOSRuntime(id: UUID) -> MacVirtualMachineRuntimeLease {
    acquireCount += 1
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

@MainActor
private final class NetworkSavedStateService:
  MacVirtualMachineSavedStateInspecting
{
  let status: MacVirtualMachineSavedStateStatus

  init(status: MacVirtualMachineSavedStateStatus) {
    self.status = status
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateStatus {
    status
  }
}

private final class NetworkLeaseReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func makeNetworkServiceMachine(
  configuration: MacVirtualMachineNetworkConfiguration
) throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Network Service",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
  manifest.networkConfiguration = configuration
  let bundle = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundle.appending(path: "HardwareModel"),
    machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
  )
}
