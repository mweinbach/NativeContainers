import Foundation

protocol MacVirtualMachineUSBAccessory: AnyObject, Sendable {
  var descriptor: MacVirtualMachineUSBDeviceDescriptor { get }
}

enum MacVirtualMachineUSBAccessoryEvent: Sendable {
  case connected(any MacVirtualMachineUSBAccessory)
  case disconnected(UInt64)
}

typealias MacVirtualMachineUSBAccessoryEventHandler =
  @MainActor @Sendable (MacVirtualMachineUSBAccessoryEvent) -> Void

@MainActor
protocol MacVirtualMachineUSBAccessoryDiscovering: AnyObject, Sendable {
  var eventHandler: MacVirtualMachineUSBAccessoryEventHandler? { get set }

  func start() async throws -> [any MacVirtualMachineUSBAccessory]
  func stop() async
}

enum MacVirtualMachineUSBControllerEvent: Equatable, Sendable {
  case disconnected(UInt64)
}

typealias MacVirtualMachineUSBControllerEventHandler =
  @MainActor @Sendable (MacVirtualMachineUSBControllerEvent) -> Void

@MainActor
protocol MacVirtualMachineUSBControlling: AnyObject, Sendable {
  var attachedDeviceIDs: Set<UInt64> { get }
  var eventHandler: MacVirtualMachineUSBControllerEventHandler? { get set }

  func attach(_ accessory: any MacVirtualMachineUSBAccessory) async throws
  func detach(deviceID: UInt64) async throws
  func close()
}

extension MacVirtualMachineUSBControlling {
  var hasAttachedDevices: Bool { !attachedDeviceIDs.isEmpty }
}

@MainActor
protocol MacVirtualMachineUSBControllerProviding: Sendable {
  func usbController(
    for target: MacVirtualMachineRuntimeTarget
  ) -> (any MacVirtualMachineUSBControlling)?
}

@MainActor
protocol MacVirtualMachineUSBManaging: Sendable {
  func snapshot(for machineID: UUID) -> MacVirtualMachineUSBSnapshot
  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineUSBSnapshot>

  func setRuntimeTarget(
    _ target: MacVirtualMachineRuntimeTarget?,
    for machineID: UUID
  )
  func discover(for machineID: UUID) async throws
  func attach(
    deviceID: UInt64,
    to target: MacVirtualMachineRuntimeTarget
  ) async throws
  func detach(
    deviceID: UInt64,
    from target: MacVirtualMachineRuntimeTarget
  ) async throws
}

@MainActor
struct UnavailableMacVirtualMachineUSBService: MacVirtualMachineUSBManaging {
  private let reason: String

  nonisolated init(
    reason: String = "USB passthrough requires macOS 27 or later."
  ) {
    self.reason = reason
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineUSBSnapshot {
    MacVirtualMachineUSBSnapshot(
      machineID: machineID,
      discoveryStatus: .unavailable(reason)
    )
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineUSBSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot(for: machineID))
      continuation.finish()
    }
  }

  func setRuntimeTarget(
    _ target: MacVirtualMachineRuntimeTarget?,
    for machineID: UUID
  ) {}

  func discover(for machineID: UUID) async throws {
    throw MacVirtualMachineUSBError.hostUnsupported
  }

  func attach(
    deviceID: UInt64,
    to target: MacVirtualMachineRuntimeTarget
  ) async throws {
    throw MacVirtualMachineUSBError.hostUnsupported
  }

  func detach(
    deviceID: UInt64,
    from target: MacVirtualMachineRuntimeTarget
  ) async throws {
    throw MacVirtualMachineUSBError.hostUnsupported
  }
}
