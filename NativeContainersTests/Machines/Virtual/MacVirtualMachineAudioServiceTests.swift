import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine audio service")
@MainActor
struct MacVirtualMachineAudioServiceTests {
  @Test
  func snapshotCombinesPersistedConfigurationAndCurrentAuthorization() async throws {
    let fixture = try AudioServiceFixture(
      configuration: MacVirtualMachineAudioConfiguration(
        revision: 3,
        isMicrophoneEnabled: true
      ),
      authorization: .denied
    )

    let snapshot = try await fixture.service.snapshot(id: fixture.machine.manifest.id)

    #expect(snapshot.configuration.revision == 3)
    #expect(snapshot.configuration.isMicrophoneEnabled)
    #expect(snapshot.microphoneAuthorization == .denied)
    #expect(await fixture.leaseStore.acquireCount == 0)
  }

  @Test
  func enablingRequestsPermissionBeforePersistingUnderTheRuntimeLease() async throws {
    let fixture = try AudioServiceFixture(
      authorization: .notDetermined,
      requestedAuthorization: .authorized
    )

    let snapshot = try await fixture.service.setMicrophoneEnabled(
      true,
      for: fixture.machine.manifest.id
    )

    #expect(snapshot.configuration.revision == 1)
    #expect(snapshot.configuration.isMicrophoneEnabled)
    #expect(snapshot.microphoneAuthorization == .authorized)
    #expect(await fixture.authorization.requestCount == 1)
    #expect(await fixture.leaseStore.acquireCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func deniedPermissionFailsBeforeAcquiringRuntimeOwnership() async throws {
    let fixture = try AudioServiceFixture(authorization: .denied)

    await #expect(throws: MacVirtualMachineAudioError.microphoneAccessDenied) {
      _ = try await fixture.service.setMicrophoneEnabled(
        true,
        for: fixture.machine.manifest.id
      )
    }

    #expect(await fixture.leaseStore.acquireCount == 0)
    #expect(await fixture.persistence.setCount == 0)
    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func savedStateBlocksMutationAndStillReleasesRuntimeOwnership() async throws {
    let fixture = try AudioServiceFixture(
      authorization: .authorized,
      savedStateStatus: .incompatible("old topology")
    )

    await #expect(
      throws: MacVirtualMachineAudioError.savedStateBlocksChanges(
        fixture.machine.manifest.id
      )
    ) {
      _ = try await fixture.service.setMicrophoneEnabled(
        true,
        for: fixture.machine.manifest.id
      )
    }

    #expect(await fixture.persistence.setCount == 0)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func disablingDoesNotRequestMicrophonePermission() async throws {
    let fixture = try AudioServiceFixture(
      configuration: MacVirtualMachineAudioConfiguration(
        revision: 7,
        isMicrophoneEnabled: true
      ),
      authorization: .denied
    )

    let snapshot = try await fixture.service.setMicrophoneEnabled(
      false,
      for: fixture.machine.manifest.id
    )

    #expect(snapshot.configuration.revision == 8)
    #expect(!snapshot.configuration.isMicrophoneEnabled)
    #expect(snapshot.microphoneAuthorization == .denied)
    #expect(await fixture.authorization.requestCount == 0)
  }
}

@MainActor
private struct AudioServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let persistence: AudioConfigurationPersistence
  let authorization: AudioAuthorizationService
  let leaseStore: AudioLeaseStore
  let releaseRecorder = AudioLeaseReleaseRecorder()
  let service: MacVirtualMachineAudioService

  init(
    configuration: MacVirtualMachineAudioConfiguration = .disconnected,
    authorization: MacVirtualMachineMicrophoneAuthorizationStatus = .authorized,
    requestedAuthorization: MacVirtualMachineMicrophoneAuthorizationStatus = .authorized,
    savedStateStatus: MacVirtualMachineSavedStateStatus = .none
  ) throws {
    machine = try makeAudioMachine(configuration: configuration)
    persistence = AudioConfigurationPersistence(configuration: configuration)
    self.authorization = AudioAuthorizationService(
      status: authorization,
      requestedStatus: requestedAuthorization
    )
    leaseStore = AudioLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    service = MacVirtualMachineAudioService(
      leasingStore: leaseStore,
      persistence: persistence,
      savedStateService: AudioSavedStateService(status: savedStateStatus),
      microphoneAuthorization: self.authorization
    )
  }
}

private actor AudioConfigurationPersistence:
  MacVirtualMachineAudioConfigurationPersisting
{
  private var configuration: MacVirtualMachineAudioConfiguration
  private(set) var setCount = 0

  init(configuration: MacVirtualMachineAudioConfiguration) {
    self.configuration = configuration
  }

  func macOSAudioConfiguration(
    id: UUID
  ) -> MacVirtualMachineAudioConfiguration {
    configuration
  }

  func setMacOSMicrophoneEnabled(
    _ isEnabled: Bool,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineAudioConfiguration {
    setCount += 1
    configuration = try configuration.settingMicrophoneEnabled(isEnabled)
    return configuration
  }
}

private actor AudioAuthorizationService:
  MacVirtualMachineMicrophoneAuthorizing
{
  private var currentStatus: MacVirtualMachineMicrophoneAuthorizationStatus
  private let requestedStatus: MacVirtualMachineMicrophoneAuthorizationStatus
  private(set) var requestCount = 0

  init(
    status: MacVirtualMachineMicrophoneAuthorizationStatus,
    requestedStatus: MacVirtualMachineMicrophoneAuthorizationStatus
  ) {
    currentStatus = status
    self.requestedStatus = requestedStatus
  }

  func status() -> MacVirtualMachineMicrophoneAuthorizationStatus {
    currentStatus
  }

  func requestAccess() -> MacVirtualMachineMicrophoneAuthorizationStatus {
    requestCount += 1
    currentStatus = requestedStatus
    return currentStatus
  }
}

private actor AudioLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: AudioLeaseReleaseRecorder
  private(set) var acquireCount = 0

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: AudioLeaseReleaseRecorder
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
private final class AudioSavedStateService: MacVirtualMachineSavedStateInspecting {
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

private final class AudioLeaseReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func makeAudioMachine(
  configuration: MacVirtualMachineAudioConfiguration
) throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Audio Service",
    guest: .macOS,
    installState: .stopped,
    resources: resources
  )
  manifest.audioConfiguration = configuration
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
