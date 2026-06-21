import Foundation

@MainActor
final class MacVirtualMachineUSBService: MacVirtualMachineUSBManaging {
  private enum AttachmentState: Equatable {
    case attaching(MacVirtualMachineRuntimeTarget)
    case attached(MacVirtualMachineRuntimeTarget)
    case detaching(MacVirtualMachineRuntimeTarget)

    var target: MacVirtualMachineRuntimeTarget {
      switch self {
      case .attaching(let target), .attached(let target), .detaching(let target):
        target
      }
    }
  }

  private let discovery: any MacVirtualMachineUSBAccessoryDiscovering
  private let controllerProvider: any MacVirtualMachineUSBControllerProviding
  private let observations: VirtualMachineRuntimeObservationStore<
    MacVirtualMachineUSBSnapshot
  >

  private var knownMachineIDs: Set<UUID> = []
  private var revisions: [UUID: UInt64] = [:]
  private var runtimeTargets: [UUID: MacVirtualMachineRuntimeTarget] = [:]
  private var accessories: [UInt64: any MacVirtualMachineUSBAccessory] = [:]
  private var attachments: [UInt64: AttachmentState] = [:]
  private var discoveryStatus: MacVirtualMachineUSBDiscoveryStatus = .notStarted

  init(
    discovery: any MacVirtualMachineUSBAccessoryDiscovering,
    controllerProvider: any MacVirtualMachineUSBControllerProviding
  ) {
    self.discovery = discovery
    self.controllerProvider = controllerProvider
    observations = VirtualMachineRuntimeObservationStore { machineID in
      MacVirtualMachineUSBSnapshot(machineID: machineID)
    }
    discovery.eventHandler = { [weak self] event in
      self?.receive(event)
    }
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineUSBSnapshot {
    knownMachineIDs.insert(machineID)
    return makeSnapshot(for: machineID)
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineUSBSnapshot> {
    knownMachineIDs.insert(machineID)
    observations.publish(makeSnapshot(for: machineID), for: machineID)
    return observations.updates(for: machineID)
  }

  func setRuntimeTarget(
    _ target: MacVirtualMachineRuntimeTarget?,
    for machineID: UUID
  ) {
    knownMachineIDs.insert(machineID)
    let previousTarget = runtimeTargets[machineID]
    guard previousTarget != target else { return }

    if let previousTarget,
      let controller = controllerProvider.usbController(for: previousTarget)
    {
      controller.eventHandler = nil
    }

    runtimeTargets[machineID] = target
    attachments = attachments.filter { _, state in
      state.target.machineID != machineID || state.target == target
    }
    publishAll()
  }

  func discover(for machineID: UUID) async throws {
    knownMachineIDs.insert(machineID)
    switch discoveryStatus {
    case .ready, .discovering:
      return
    case .notStarted, .failed:
      break
    case .unavailable:
      throw MacVirtualMachineUSBError.hostUnsupported
    }

    discoveryStatus = .discovering
    publishAll()
    do {
      let connected = try await discovery.start()
      for accessory in connected {
        accessories[accessory.descriptor.id] = accessory
      }
      discoveryStatus = .ready
      publishAll()
    } catch {
      discoveryStatus = .failed(error.localizedDescription)
      publishAll()
      throw error
    }
  }

  func attach(
    deviceID: UInt64,
    to target: MacVirtualMachineRuntimeTarget
  ) async throws {
    try requireCurrent(target)
    guard let accessory = accessories[deviceID] else {
      throw MacVirtualMachineUSBError.accessoryNotFound(deviceID)
    }
    try requireAvailable(deviceID, for: target)
    guard let controller = controllerProvider.usbController(for: target) else {
      throw MacVirtualMachineUSBError.controllerUnavailable
    }

    controller.eventHandler = { [weak self] event in
      self?.receive(event, from: target)
    }
    attachments[deviceID] = .attaching(target)
    publishAll()

    do {
      try await controller.attach(accessory)
      guard runtimeTargets[target.machineID] == target,
        attachments[deviceID] == .attaching(target)
      else {
        try? await controller.detach(deviceID: deviceID)
        attachments[deviceID] = nil
        publishAll()
        throw MacVirtualMachineUSBError.staleTarget(target)
      }
      attachments[deviceID] = .attached(target)
      publishAll()
    } catch {
      if attachments[deviceID] == .attaching(target) {
        attachments[deviceID] = nil
      }
      publishAll()
      throw error
    }
  }

  func detach(
    deviceID: UInt64,
    from target: MacVirtualMachineRuntimeTarget
  ) async throws {
    try requireCurrent(target)
    guard let controller = controllerProvider.usbController(for: target) else {
      throw MacVirtualMachineUSBError.controllerUnavailable
    }

    switch attachments[deviceID] {
    case .attached(let attachedTarget) where attachedTarget == target:
      break
    case .attaching(let operationTarget) where operationTarget == target:
      throw MacVirtualMachineUSBError.operationInProgress(deviceID)
    case .detaching(let operationTarget) where operationTarget == target:
      throw MacVirtualMachineUSBError.operationInProgress(deviceID)
    case .some:
      throw MacVirtualMachineUSBError.attachedToAnotherVirtualMachine(deviceID)
    case nil:
      throw MacVirtualMachineUSBError.notAttached(deviceID)
    }

    attachments[deviceID] = .detaching(target)
    publishAll()
    do {
      try await controller.detach(deviceID: deviceID)
      if runtimeTargets[target.machineID] == target {
        attachments[deviceID] = nil
      }
      publishAll()
    } catch {
      if runtimeTargets[target.machineID] == target,
        accessories[deviceID] != nil,
        attachments[deviceID] == .detaching(target)
      {
        attachments[deviceID] = .attached(target)
      } else {
        attachments[deviceID] = nil
      }
      publishAll()
      throw error
    }
  }

  private func requireCurrent(
    _ target: MacVirtualMachineRuntimeTarget
  ) throws {
    guard let current = runtimeTargets[target.machineID] else {
      throw MacVirtualMachineUSBError.runtimeUnavailable(target.machineID)
    }
    guard current == target else {
      throw MacVirtualMachineUSBError.staleTarget(target)
    }
  }

  private func requireAvailable(
    _ deviceID: UInt64,
    for target: MacVirtualMachineRuntimeTarget
  ) throws {
    switch attachments[deviceID] {
    case nil:
      return
    case .attached(let attachedTarget) where attachedTarget == target:
      throw MacVirtualMachineUSBError.alreadyAttached(deviceID)
    case .attaching(let operationTarget) where operationTarget == target:
      throw MacVirtualMachineUSBError.operationInProgress(deviceID)
    case .detaching(let operationTarget) where operationTarget == target:
      throw MacVirtualMachineUSBError.operationInProgress(deviceID)
    case .some:
      throw MacVirtualMachineUSBError.attachedToAnotherVirtualMachine(deviceID)
    }
  }

  private func receive(_ event: MacVirtualMachineUSBAccessoryEvent) {
    switch event {
    case .connected(let accessory):
      accessories[accessory.descriptor.id] = accessory
    case .disconnected(let deviceID):
      accessories[deviceID] = nil
      attachments[deviceID] = nil
    }
    publishAll()
  }

  private func receive(
    _ event: MacVirtualMachineUSBControllerEvent,
    from target: MacVirtualMachineRuntimeTarget
  ) {
    switch event {
    case .disconnected(let deviceID):
      guard attachments[deviceID]?.target == target else { return }
      attachments[deviceID] = nil
      publishAll()
    }
  }

  private func publishAll() {
    for machineID in knownMachineIDs {
      revisions[machineID] = nextRevision(after: revisions[machineID, default: 0])
      observations.publish(makeSnapshot(for: machineID), for: machineID)
    }
  }

  private func makeSnapshot(
    for machineID: UUID
  ) -> MacVirtualMachineUSBSnapshot {
    let devices = accessories.values
      .map(\.descriptor)
      .sorted {
        if $0.vendorProductIdentifier == $1.vendorProductIdentifier {
          return $0.id < $1.id
        }
        return $0.vendorProductIdentifier < $1.vendorProductIdentifier
      }
      .map { descriptor in
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: descriptor,
          state: projectedState(
            attachments[descriptor.id],
            for: machineID
          )
        )
      }
    return MacVirtualMachineUSBSnapshot(
      machineID: machineID,
      revision: revisions[machineID, default: 0],
      target: runtimeTargets[machineID],
      discoveryStatus: discoveryStatus,
      devices: devices
    )
  }

  private func projectedState(
    _ state: AttachmentState?,
    for machineID: UUID
  ) -> MacVirtualMachineUSBDeviceState {
    guard let state else { return .available }
    guard state.target.machineID == machineID else {
      return .inUseByAnotherVirtualMachine
    }
    switch state {
    case .attaching:
      return .attaching
    case .attached:
      return .attached
    case .detaching:
      return .detaching
    }
  }

  private func nextRevision(after revision: UInt64) -> UInt64 {
    revision == .max ? .max : revision + 1
  }
}
