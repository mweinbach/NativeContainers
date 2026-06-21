import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("macOS virtual machine USB model")
struct MacVirtualMachineUSBModelTests {
  @Test
  func actionsUseTheRuntimeGenerationCapturedByTheModel() async throws {
    let machineID = UUID()
    let target = makeUSBModelTarget(machineID: machineID)
    let runtime = USBModelRuntimeService(
      snapshot: MacVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        target: target,
        state: .running
      )
    )
    let service = USBModelService(machineID: machineID)
    let model = MacVirtualMachineUSBModel(
      machineID: machineID,
      service: service,
      runtime: runtime
    )

    #expect(model.canAttachDevices)
    #expect(model.snapshot.target == target)
    #expect(service.runtimeTargets[machineID] == target)

    #expect(await model.attach(deviceID: 12))
    #expect(service.attachCalls == [
      USBModelDeviceCall(deviceID: 12, target: target)
    ])

    #expect(await model.detach(deviceID: 12))
    #expect(service.detachCalls == [
      USBModelDeviceCall(deviceID: 12, target: target)
    ])
  }

  @Test
  func runtimeUpdatesReplaceAndClearThePinnedGeneration() async {
    let machineID = UUID()
    let first = makeUSBModelTarget(machineID: machineID)
    let replacement = makeUSBModelTarget(machineID: machineID)
    let runtime = USBModelRuntimeService(
      snapshot: MacVirtualMachineRuntimeSnapshot(
        machineID: machineID,
        target: first,
        state: .running
      )
    )
    let service = USBModelService(machineID: machineID)
    let model = MacVirtualMachineUSBModel(
      machineID: machineID,
      service: service,
      runtime: runtime
    )
    model.observe()

    runtime.publish(target: replacement, state: .paused)
    await waitForUSBModel {
      model.snapshot.target == replacement && model.runtimeState == .paused
    }
    #expect(model.canAttachDevices)
    #expect(service.runtimeTargets[machineID] == replacement)

    runtime.publish(target: nil, state: .stopped)
    await waitForUSBModel {
      model.snapshot.target == nil && model.runtimeState == .stopped
    }
    #expect(!model.canAttachDevices)

    model.stopObserving()
    #expect(service.runtimeTargets[machineID] == nil)
  }

  @Test
  func discoveryFailureIsVisibleAndRetryable() async {
    let machineID = UUID()
    let runtime = USBModelRuntimeService(
      snapshot: MacVirtualMachineRuntimeSnapshot(machineID: machineID)
    )
    let service = USBModelService(
      machineID: machineID,
      discoveryError: USBModelTestError.expected
    )
    let model = MacVirtualMachineUSBModel(
      machineID: machineID,
      service: service,
      runtime: runtime
    )

    #expect(!model.isDiscovering)
    let succeeded = await model.discover()

    #expect(!succeeded)
    #expect(!model.isDiscovering)
    #expect(model.errorMessage == USBModelTestError.expected.localizedDescription)
    #expect(service.discoveryCount == 1)

    model.clearError()
    #expect(model.errorMessage == nil)
  }
}

private struct USBModelDeviceCall: Equatable {
  let deviceID: UInt64
  let target: MacVirtualMachineRuntimeTarget
}

@MainActor
private final class USBModelService: MacVirtualMachineUSBManaging {
  private let machineID: UUID
  private let discoveryError: USBModelTestError?
  private let observations:
    VirtualMachineRuntimeObservationStore<MacVirtualMachineUSBSnapshot>

  private(set) var runtimeTargets: [UUID: MacVirtualMachineRuntimeTarget] = [:]
  private(set) var discoveryCount = 0
  private(set) var attachCalls: [USBModelDeviceCall] = []
  private(set) var detachCalls: [USBModelDeviceCall] = []
  private var revision: UInt64 = 0

  init(
    machineID: UUID,
    discoveryError: USBModelTestError? = nil
  ) {
    self.machineID = machineID
    self.discoveryError = discoveryError
    observations = VirtualMachineRuntimeObservationStore { machineID in
      MacVirtualMachineUSBSnapshot(
        machineID: machineID,
        discoveryStatus: .ready
      )
    }
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineUSBSnapshot {
    MacVirtualMachineUSBSnapshot(
      machineID: machineID,
      revision: revision,
      target: runtimeTargets[machineID],
      discoveryStatus: .ready,
      devices: [
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: MacVirtualMachineUSBDeviceDescriptor(
            id: 12,
            vendorID: 1,
            productID: 2
          ),
          state: .available
        )
      ]
    )
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineUSBSnapshot> {
    observations.publish(snapshot(for: machineID), for: machineID)
    return observations.updates(for: machineID)
  }

  func setRuntimeTarget(
    _ target: MacVirtualMachineRuntimeTarget?,
    for machineID: UUID
  ) {
    runtimeTargets[machineID] = target
    revision += 1
    observations.publish(snapshot(for: machineID), for: machineID)
  }

  func discover(for machineID: UUID) async throws {
    discoveryCount += 1
    if let discoveryError { throw discoveryError }
  }

  func attach(
    deviceID: UInt64,
    to target: MacVirtualMachineRuntimeTarget
  ) async throws {
    attachCalls.append(USBModelDeviceCall(deviceID: deviceID, target: target))
  }

  func detach(
    deviceID: UInt64,
    from target: MacVirtualMachineRuntimeTarget
  ) async throws {
    detachCalls.append(USBModelDeviceCall(deviceID: deviceID, target: target))
  }
}

@MainActor
private final class USBModelRuntimeService: MacVirtualMachineRuntimeManaging {
  private let observations = MacVirtualMachineRuntimeObservations()
  private var current: MacVirtualMachineRuntimeSnapshot

  init(snapshot: MacVirtualMachineRuntimeSnapshot) {
    current = snapshot
    observations.publish(
      machineID: snapshot.machineID,
      target: snapshot.target,
      state: snapshot.state,
      savedStateStatus: snapshot.savedStateStatus,
      saveRestoreSupport: snapshot.saveRestoreSupport
    )
    current = observations.snapshot(for: snapshot.machineID)
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    current
  }

  func updates(
    for machineID: UUID
  ) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    observations.updates(for: machineID)
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? {
    nil
  }

  func refreshSavedState(id: UUID) async {}
  func start(id: UUID) async throws {}
  func startFresh(id: UUID) async throws {}
  func pause(target: MacVirtualMachineRuntimeTarget) async throws {}
  func resume(target: MacVirtualMachineRuntimeTarget) async throws {}
  func suspend(target: MacVirtualMachineRuntimeTarget) async throws {}
  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {}
  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {}
  func discardSavedState(id: UUID) async throws {}

  func publish(
    target: MacVirtualMachineRuntimeTarget?,
    state: MacVirtualMachineRuntimeState
  ) {
    observations.publish(
      machineID: current.machineID,
      target: target,
      state: state
    )
    current = observations.snapshot(for: current.machineID)
  }
}

private enum USBModelTestError: LocalizedError {
  case expected

  var errorDescription: String? {
    "Expected USB model failure."
  }
}

private func makeUSBModelTarget(
  machineID: UUID
) -> MacVirtualMachineRuntimeTarget {
  MacVirtualMachineRuntimeTarget(
    machineID: machineID,
    generation: UUID()
  )
}

@MainActor
private func waitForUSBModel(
  _ condition: () -> Bool
) async {
  for _ in 0..<40 {
    if condition() { return }
    await Task.yield()
  }
}
