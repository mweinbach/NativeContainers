import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("macOS virtual machine USB service")
struct MacVirtualMachineUSBServiceTests {
  @Test
  func discoveryPublishesSortedDevicesAndDisconnects() async throws {
    let machineID = UUID()
    let first = USBServiceAccessory(id: 1, vendorID: 0x05AC, productID: 0x1000)
    let second = USBServiceAccessory(id: 2, vendorID: 0x1234, productID: 0x0001)
    let discovery = USBServiceDiscovery(accessories: [second, first])
    let service = MacVirtualMachineUSBService(
      discovery: discovery,
      controllerProvider: USBServiceControllerProvider()
    )

    #expect(service.snapshot(for: machineID).discoveryStatus == .notStarted)
    try await service.discover(for: machineID)

    var snapshot = service.snapshot(for: machineID)
    #expect(snapshot.discoveryStatus == .ready)
    #expect(snapshot.devices.map(\.id) == [1, 2])
    #expect(snapshot.devices.allSatisfy { $0.state == .available })
    #expect(discovery.startCount == 1)

    discovery.emit(.disconnected(1))
    snapshot = service.snapshot(for: machineID)
    #expect(snapshot.devices.map(\.id) == [2])

    try await service.discover(for: machineID)
    #expect(discovery.startCount == 1)
  }

  @Test
  func attachAndDetachUseTheExactRuntimeController() async throws {
    let machineID = UUID()
    let target = makeUSBServiceTarget(machineID: machineID)
    let accessory = USBServiceAccessory(id: 7)
    let discovery = USBServiceDiscovery(accessories: [accessory])
    let controller = USBServiceController()
    let provider = USBServiceControllerProvider(
      controllers: [target: controller]
    )
    let service = MacVirtualMachineUSBService(
      discovery: discovery,
      controllerProvider: provider
    )

    service.setRuntimeTarget(target, for: machineID)
    try await service.discover(for: machineID)
    try await service.attach(deviceID: accessory.descriptor.id, to: target)

    var snapshot = service.snapshot(for: machineID)
    #expect(snapshot.target == target)
    #expect(snapshot.devices.map(\.state) == [.attached])
    #expect(controller.attachedDeviceIDs == [7])
    #expect(controller.attachCalls == [7])

    try await service.detach(deviceID: 7, from: target)
    snapshot = service.snapshot(for: machineID)
    #expect(snapshot.devices.map(\.state) == [.available])
    #expect(controller.attachedDeviceIDs.isEmpty)
    #expect(controller.detachCalls == [7])
  }

  @Test
  func attachmentOwnershipIsProjectedAcrossVirtualMachines() async throws {
    let firstMachineID = UUID()
    let secondMachineID = UUID()
    let firstTarget = makeUSBServiceTarget(machineID: firstMachineID)
    let secondTarget = makeUSBServiceTarget(machineID: secondMachineID)
    let accessory = USBServiceAccessory(id: 8)
    let discovery = USBServiceDiscovery(accessories: [accessory])
    let provider = USBServiceControllerProvider(
      controllers: [
        firstTarget: USBServiceController(),
        secondTarget: USBServiceController(),
      ]
    )
    let service = MacVirtualMachineUSBService(
      discovery: discovery,
      controllerProvider: provider
    )

    service.setRuntimeTarget(firstTarget, for: firstMachineID)
    service.setRuntimeTarget(secondTarget, for: secondMachineID)
    try await service.discover(for: firstMachineID)
    _ = service.snapshot(for: secondMachineID)
    try await service.attach(deviceID: 8, to: firstTarget)

    #expect(
      service.snapshot(for: firstMachineID).devices.first?.state == .attached
    )
    #expect(
      service.snapshot(for: secondMachineID).devices.first?.state
        == .inUseByAnotherVirtualMachine
    )
    await #expect(
      throws: MacVirtualMachineUSBError.attachedToAnotherVirtualMachine(8)
    ) {
      try await service.attach(deviceID: 8, to: secondTarget)
    }

    service.setRuntimeTarget(nil, for: firstMachineID)
    #expect(
      service.snapshot(for: secondMachineID).devices.first?.state == .available
    )
  }

  @Test
  func runtimeReplacementUnwindsAnAttachThatFinishesLate() async throws {
    let machineID = UUID()
    let target = makeUSBServiceTarget(machineID: machineID)
    let replacement = makeUSBServiceTarget(machineID: machineID)
    let accessory = USBServiceAccessory(id: 9)
    let discovery = USBServiceDiscovery(accessories: [accessory])
    let controller = USBServiceController(attachWaits: true)
    let replacementController = USBServiceController()
    let provider = USBServiceControllerProvider(
      controllers: [
        target: controller,
        replacement: replacementController,
      ]
    )
    let service = MacVirtualMachineUSBService(
      discovery: discovery,
      controllerProvider: provider
    )

    service.setRuntimeTarget(target, for: machineID)
    try await service.discover(for: machineID)
    let attachment = Task {
      try await service.attach(deviceID: 9, to: target)
    }
    await controller.waitUntilAttachBegins()

    service.setRuntimeTarget(replacement, for: machineID)
    controller.completeAttach()

    await #expect(
      throws: MacVirtualMachineUSBError.staleTarget(target)
    ) {
      try await attachment.value
    }
    #expect(controller.attachedDeviceIDs.isEmpty)
    #expect(controller.detachCalls == [9])
    #expect(service.snapshot(for: machineID).target == replacement)
    #expect(service.snapshot(for: machineID).devices.first?.state == .available)
  }

  @Test
  func controllerDisconnectClearsAttachmentOnlyForItsGeneration() async throws {
    let machineID = UUID()
    let target = makeUSBServiceTarget(machineID: machineID)
    let accessory = USBServiceAccessory(id: 10)
    let discovery = USBServiceDiscovery(accessories: [accessory])
    let controller = USBServiceController()
    let service = MacVirtualMachineUSBService(
      discovery: discovery,
      controllerProvider: USBServiceControllerProvider(
        controllers: [target: controller]
      )
    )

    service.setRuntimeTarget(target, for: machineID)
    try await service.discover(for: machineID)
    try await service.attach(deviceID: 10, to: target)
    controller.emit(.disconnected(10))

    #expect(service.snapshot(for: machineID).devices.first?.state == .available)
  }
}

private final class USBServiceAccessory: MacVirtualMachineUSBAccessory {
  let descriptor: MacVirtualMachineUSBDeviceDescriptor

  init(
    id: UInt64,
    vendorID: UInt16 = 0x05AC,
    productID: UInt16 = 0x0001
  ) {
    descriptor = MacVirtualMachineUSBDeviceDescriptor(
      id: id,
      vendorID: vendorID,
      productID: productID
    )
  }
}

@MainActor
private final class USBServiceDiscovery: MacVirtualMachineUSBAccessoryDiscovering {
  var eventHandler: MacVirtualMachineUSBAccessoryEventHandler?
  private(set) var startCount = 0
  private let accessories: [any MacVirtualMachineUSBAccessory]

  init(accessories: [any MacVirtualMachineUSBAccessory]) {
    self.accessories = accessories
  }

  func start() async throws -> [any MacVirtualMachineUSBAccessory] {
    startCount += 1
    return accessories
  }

  func stop() async {}

  func emit(_ event: MacVirtualMachineUSBAccessoryEvent) {
    eventHandler?(event)
  }
}

@MainActor
private final class USBServiceController: MacVirtualMachineUSBControlling {
  var attachedDeviceIDs: Set<UInt64> = []
  var eventHandler: MacVirtualMachineUSBControllerEventHandler?
  private(set) var attachCalls: [UInt64] = []
  private(set) var detachCalls: [UInt64] = []

  private let attachWaits: Bool
  private var attachContinuation: CheckedContinuation<Void, Never>?
  private var attachWaiters: [CheckedContinuation<Void, Never>] = []

  init(attachWaits: Bool = false) {
    self.attachWaits = attachWaits
  }

  func attach(_ accessory: any MacVirtualMachineUSBAccessory) async throws {
    let identifier = accessory.descriptor.id
    attachCalls.append(identifier)
    let waiters = attachWaiters
    attachWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if attachWaits {
      await withCheckedContinuation { continuation in
        attachContinuation = continuation
      }
    }
    attachedDeviceIDs.insert(identifier)
  }

  func detach(deviceID: UInt64) async throws {
    detachCalls.append(deviceID)
    attachedDeviceIDs.remove(deviceID)
  }

  func close() {
    attachedDeviceIDs.removeAll()
    eventHandler = nil
  }

  func waitUntilAttachBegins() async {
    if !attachCalls.isEmpty { return }
    await withCheckedContinuation { continuation in
      attachWaiters.append(continuation)
    }
  }

  func completeAttach() {
    attachContinuation?.resume()
    attachContinuation = nil
  }

  func emit(_ event: MacVirtualMachineUSBControllerEvent) {
    if case .disconnected(let identifier) = event {
      attachedDeviceIDs.remove(identifier)
    }
    eventHandler?(event)
  }
}

@MainActor
private final class USBServiceControllerProvider:
  MacVirtualMachineUSBControllerProviding
{
  private let controllers:
    [MacVirtualMachineRuntimeTarget: USBServiceController]

  init(
    controllers: [MacVirtualMachineRuntimeTarget: USBServiceController] = [:]
  ) {
    self.controllers = controllers
  }

  func usbController(
    for target: MacVirtualMachineRuntimeTarget
  ) -> (any MacVirtualMachineUSBControlling)? {
    controllers[target]
  }
}

private func makeUSBServiceTarget(
  machineID: UUID
) -> MacVirtualMachineRuntimeTarget {
  MacVirtualMachineRuntimeTarget(
    machineID: machineID,
    generation: UUID()
  )
}
