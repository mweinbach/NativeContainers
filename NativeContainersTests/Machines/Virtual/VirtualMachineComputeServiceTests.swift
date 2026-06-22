import Foundation
import Testing

@testable import NativeContainers

@Suite("Virtual machine compute services")
@MainActor
struct VirtualMachineComputeServiceTests {
  @Test
  func macSnapshotUsesPersistedGuestFloorsWithoutTakingRuntimeLease() async throws {
    let fixture = try ComputeServiceFixture()

    let snapshot = try await fixture.macService.snapshot(
      id: fixture.macMachine.manifest.id
    )

    #expect(snapshot.configuration.cpuCount == 6)
    #expect(
      snapshot.configuration.memoryBytes
        == 12 * VirtualMachineResources.bytesPerGiB
    )
    #expect(snapshot.limits.minimumCPUCount == 4)
    #expect(
      snapshot.limits.minimumMemoryBytes
        == 8 * VirtualMachineResources.bytesPerGiB
    )
    #expect(await fixture.macLeaseStore.acquireCount == 0)
  }

  @Test
  func macMutationPersistsUnderLeaseAndReleasesOwnership() async throws {
    let fixture = try ComputeServiceFixture()

    let snapshot = try await fixture.macService.setConfiguration(
      VirtualMachineComputeConfiguration(
        cpuCount: 8,
        memoryBytes: 16 * VirtualMachineResources.bytesPerGiB
      ),
      for: fixture.macMachine.manifest.id
    )

    #expect(snapshot.configuration.cpuCount == 8)
    #expect(
      snapshot.configuration.memoryBytes
        == 16 * VirtualMachineResources.bytesPerGiB
    )
    #expect(await fixture.persistence.macSetCount == 1)
    #expect(await fixture.macLeaseStore.acquireCount == 1)
    #expect(fixture.macReleaseRecorder.count == 1)
  }

  @Test
  func macSavedStateBlocksMutationAndReleasesOwnership() async throws {
    let fixture = try ComputeServiceFixture(
      savedStateStatus: .incompatible("old compute allocation")
    )

    await #expect(
      throws: VirtualMachineComputeError.savedStateBlocksChanges(
        fixture.macMachine.manifest.id
      )
    ) {
      _ = try await fixture.macService.setConfiguration(
        VirtualMachineComputeConfiguration(
          cpuCount: 8,
          memoryBytes: 16 * VirtualMachineResources.bytesPerGiB
        ),
        for: fixture.macMachine.manifest.id
      )
    }

    #expect(await fixture.persistence.macSetCount == 0)
    #expect(fixture.macReleaseRecorder.count == 1)
  }

  @Test
  func linuxMutationCanReduceToApplePlatformFloor() async throws {
    let fixture = try ComputeServiceFixture()

    let snapshot = try await fixture.linuxService.setConfiguration(
      VirtualMachineComputeConfiguration(
        cpuCount: 2,
        memoryBytes: 4 * VirtualMachineResources.bytesPerGiB
      ),
      for: fixture.linuxMachine.manifest.id
    )

    #expect(snapshot.configuration.cpuCount == 2)
    #expect(
      snapshot.configuration.memoryBytes
        == 4 * VirtualMachineResources.bytesPerGiB
    )
    #expect(await fixture.persistence.linuxSetCount == 1)
    #expect(await fixture.linuxLeaseStore.acquireCount == 1)
    #expect(fixture.linuxReleaseRecorder.count == 1)
  }

  @Test
  func linuxSavedStateBlocksMutationAndReleasesOwnership() async throws {
    let fixture = try ComputeServiceFixture(
      savedStateStatus: .available(
        VirtualMachineSavedStateSummary(
          createdAt: Date(timeIntervalSince1970: 1_000),
          stateSizeBytes: 4_096
        )
      )
    )

    await #expect(
      throws: VirtualMachineComputeError.savedStateBlocksChanges(
        fixture.linuxMachine.manifest.id
      )
    ) {
      _ = try await fixture.linuxService.setConfiguration(
        VirtualMachineComputeConfiguration(
          cpuCount: 2,
          memoryBytes: 4 * VirtualMachineResources.bytesPerGiB
        ),
        for: fixture.linuxMachine.manifest.id
      )
    }

    #expect(await fixture.persistence.linuxSetCount == 0)
    #expect(fixture.linuxReleaseRecorder.count == 1)
  }
}

@MainActor
private struct ComputeServiceFixture {
  let macMachine: ResolvedMacVirtualMachine
  let linuxMachine: ResolvedLinuxVirtualMachine
  let persistence: ComputePersistence
  let macLeaseStore: ComputeMacLeaseStore
  let linuxLeaseStore: ComputeLinuxLeaseStore
  let macReleaseRecorder = ComputeReleaseRecorder()
  let linuxReleaseRecorder = ComputeReleaseRecorder()
  let macService: MacVirtualMachineComputeService
  let linuxService: LinuxVirtualMachineComputeService

  init(
    savedStateStatus: MacVirtualMachineSavedStateStatus = .none
  ) throws {
    let limits = computePlatformLimits()
    macMachine = try makeComputeMacMachine()
    linuxMachine = try makeComputeLinuxMachine()
    persistence = ComputePersistence(
      macState: VirtualMachineComputeState(manifest: macMachine.manifest),
      linuxState: VirtualMachineComputeState(manifest: linuxMachine.manifest)
    )
    macLeaseStore = ComputeMacLeaseStore(
      machine: macMachine,
      releaseRecorder: macReleaseRecorder
    )
    linuxLeaseStore = ComputeLinuxLeaseStore(
      machine: linuxMachine,
      releaseRecorder: linuxReleaseRecorder
    )
    macService = MacVirtualMachineComputeService(
      leasingStore: macLeaseStore,
      persistence: persistence,
      savedStateService: ComputeSavedStateService(status: savedStateStatus),
      platformLimits: limits
    )
    linuxService = LinuxVirtualMachineComputeService(
      leasingStore: linuxLeaseStore,
      persistence: persistence,
      savedStateService: ComputeSavedStateService(status: savedStateStatus),
      platformLimits: limits
    )
  }
}

private actor ComputePersistence:
  MacVirtualMachineComputePersisting,
  LinuxVirtualMachineComputePersisting
{
  private var macState: VirtualMachineComputeState
  private var linuxState: VirtualMachineComputeState
  private(set) var macSetCount = 0
  private(set) var linuxSetCount = 0

  init(
    macState: VirtualMachineComputeState,
    linuxState: VirtualMachineComputeState
  ) {
    self.macState = macState
    self.linuxState = linuxState
  }

  func macOSComputeState(id: UUID) -> VirtualMachineComputeState {
    macState
  }

  func setMacOSComputeConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    platformLimits: VirtualMachineComputeLimits,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> VirtualMachineComputeState {
    let limits = try macState.snapshot(platformLimits: platformLimits).limits
    try limits.validate(configuration)
    macSetCount += 1
    macState = VirtualMachineComputeState(
      guest: macState.guest,
      configuration: configuration,
      diskBytes: macState.diskBytes,
      guestMinimumCPUCount: macState.guestMinimumCPUCount,
      guestMinimumMemoryBytes: macState.guestMinimumMemoryBytes
    )
    return macState
  }

  func linuxComputeState(id: UUID) -> VirtualMachineComputeState {
    linuxState
  }

  func setLinuxComputeConfiguration(
    _ configuration: VirtualMachineComputeConfiguration,
    platformLimits: VirtualMachineComputeLimits,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> VirtualMachineComputeState {
    let limits = try linuxState.snapshot(platformLimits: platformLimits).limits
    try limits.validate(configuration)
    linuxSetCount += 1
    linuxState = VirtualMachineComputeState(
      guest: linuxState.guest,
      configuration: configuration,
      diskBytes: linuxState.diskBytes,
      guestMinimumCPUCount: linuxState.guestMinimumCPUCount,
      guestMinimumMemoryBytes: linuxState.guestMinimumMemoryBytes
    )
    return linuxState
  }
}

private actor ComputeMacLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: ComputeReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: ComputeReleaseRecorder
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

private actor ComputeLinuxLeaseStore: LinuxVirtualMachineRuntimeLeasing {
  let machine: ResolvedLinuxVirtualMachine
  let releaseRecorder: ComputeReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedLinuxVirtualMachine,
    releaseRecorder: ComputeReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireLinuxRuntime(id: UUID) -> LinuxVirtualMachineRuntimeLease {
    acquireCount += 1
    return LinuxVirtualMachineRuntimeLease(
      machine: machine,
      target: LinuxVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

@MainActor
private final class ComputeSavedStateService:
  MacVirtualMachineSavedStateInspecting,
  LinuxVirtualMachineSavedStateInspecting
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

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) -> LinuxVirtualMachineSavedStateStatus {
    status
  }
}

private final class ComputeReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func computePlatformLimits() -> VirtualMachineComputeLimits {
  VirtualMachineComputeLimits(
    minimumCPUCount: 1,
    maximumCPUCount: 12,
    minimumMemoryBytes: VirtualMachineResources.bytesPerGiB,
    maximumMemoryBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
}

private func makeComputeMacMachine() throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Compute Mac",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 6,
      memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
  manifest.macOSMinimumCPUCount = 4
  manifest.macOSMinimumMemoryBytes =
    8 * VirtualMachineResources.bytesPerGiB
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

private func makeComputeLinuxMachine() throws -> ResolvedLinuxVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Compute Linux",
    guest: .linux,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 32 * VirtualMachineResources.bytesPerGiB
    )
  )
  manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
    efiVariableStorePath: "Platform/EFI",
    machineIdentifierPath: "Platform/MachineIdentifier",
    installationMediaPath: nil,
    macAddress: "02:00:00:00:00:01"
  )
  let bundle = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedLinuxVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    efiVariableStoreURL: bundle.appending(path: "Platform/EFI"),
    machineIdentifierURL: bundle.appending(path: "Platform/MachineIdentifier"),
    installationMediaURL: nil
  )
}
