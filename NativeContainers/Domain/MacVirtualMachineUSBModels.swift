import Foundation

struct MacVirtualMachineUSBDeviceDescriptor: Identifiable, Equatable, Sendable {
  static let descriptorLength = 18
  static let deviceDescriptorType: UInt8 = 1

  let id: UInt64
  let vendorID: UInt16
  let productID: UInt16
  let deviceClass: UInt8
  let deviceSubclass: UInt8
  let deviceProtocol: UInt8

  init(
    id: UInt64,
    vendorID: UInt16,
    productID: UInt16,
    deviceClass: UInt8 = 0,
    deviceSubclass: UInt8 = 0,
    deviceProtocol: UInt8 = 0
  ) {
    self.id = id
    self.vendorID = vendorID
    self.productID = productID
    self.deviceClass = deviceClass
    self.deviceSubclass = deviceSubclass
    self.deviceProtocol = deviceProtocol
  }

  init(id: UInt64, deviceDescriptorData: Data) throws {
    guard deviceDescriptorData.count >= Self.descriptorLength,
      Int(deviceDescriptorData[0]) >= Self.descriptorLength,
      deviceDescriptorData[1] == Self.deviceDescriptorType
    else {
      throw MacVirtualMachineUSBError.invalidDeviceDescriptor
    }

    self.init(
      id: id,
      vendorID: Self.littleEndianUInt16(in: deviceDescriptorData, offset: 8),
      productID: Self.littleEndianUInt16(in: deviceDescriptorData, offset: 10),
      deviceClass: deviceDescriptorData[4],
      deviceSubclass: deviceDescriptorData[5],
      deviceProtocol: deviceDescriptorData[6]
    )
  }

  var vendorProductIdentifier: String {
    String(format: "%04X:%04X", vendorID, productID)
  }

  private static func littleEndianUInt16(in data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }
}

enum MacVirtualMachineUSBDeviceState: Equatable, Sendable {
  case available
  case attaching
  case attached
  case detaching
  case inUseByAnotherVirtualMachine
}

struct MacVirtualMachineUSBDeviceSnapshot: Identifiable, Equatable, Sendable {
  let descriptor: MacVirtualMachineUSBDeviceDescriptor
  let state: MacVirtualMachineUSBDeviceState

  var id: UInt64 { descriptor.id }
}

enum MacVirtualMachineUSBDiscoveryStatus: Equatable, Sendable {
  case notStarted
  case discovering
  case ready
  case unavailable(String)
  case failed(String)
}

struct MacVirtualMachineUSBSnapshot: Equatable, Sendable {
  let machineID: UUID
  let revision: UInt64
  let target: MacVirtualMachineRuntimeTarget?
  let discoveryStatus: MacVirtualMachineUSBDiscoveryStatus
  let devices: [MacVirtualMachineUSBDeviceSnapshot]

  init(
    machineID: UUID,
    revision: UInt64 = 0,
    target: MacVirtualMachineRuntimeTarget? = nil,
    discoveryStatus: MacVirtualMachineUSBDiscoveryStatus = .notStarted,
    devices: [MacVirtualMachineUSBDeviceSnapshot] = []
  ) {
    self.machineID = machineID
    self.revision = revision
    self.target = target
    self.discoveryStatus = discoveryStatus
    self.devices = devices
  }

  var hasAttachedDevices: Bool {
    devices.contains { $0.state == .attached || $0.state == .detaching }
  }
}

enum MacVirtualMachineUSBError: LocalizedError, Equatable, Sendable {
  case hostUnsupported
  case invalidDeviceDescriptor
  case accessoryNotFound(UInt64)
  case incompatibleAccessory
  case runtimeUnavailable(UUID)
  case staleTarget(MacVirtualMachineRuntimeTarget)
  case controllerUnavailable
  case operationInProgress(UInt64)
  case alreadyAttached(UInt64)
  case attachedToAnotherVirtualMachine(UInt64)
  case notAttached(UInt64)
  case attachedDevicesBlockSuspend

  var errorDescription: String? {
    switch self {
    case .hostUnsupported:
      "USB passthrough requires macOS 27 or later."
    case .invalidDeviceDescriptor:
      "The USB accessory reported an invalid device descriptor."
    case .accessoryNotFound(let identifier):
      "USB accessory \(identifier) is no longer connected to this Mac."
    case .incompatibleAccessory:
      "The selected USB accessory cannot be passed through to a virtual machine."
    case .runtimeUnavailable(let identifier):
      "Start virtual machine \(identifier.uuidString) before attaching a USB accessory."
    case .staleTarget:
      "The virtual machine restarted before the USB operation completed."
    case .controllerUnavailable:
      "This virtual machine does not have an available USB controller."
    case .operationInProgress:
      "A USB operation is already in progress for this accessory."
    case .alreadyAttached:
      "This USB accessory is already attached to the virtual machine."
    case .attachedToAnotherVirtualMachine:
      "This USB accessory is already attached to another virtual machine."
    case .notAttached:
      "This USB accessory is not attached to the virtual machine."
    case .attachedDevicesBlockSuspend:
      "Detach USB accessories before suspending the virtual machine."
    }
  }
}
