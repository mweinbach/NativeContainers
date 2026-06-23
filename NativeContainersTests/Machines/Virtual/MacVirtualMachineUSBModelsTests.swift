import Foundation
import Testing

@testable import NativeContainers

@Suite("macOS virtual machine USB models")
struct MacVirtualMachineUSBModelsTests {
  @Test
  func parsesStandardUSBDeviceDescriptor() throws {
    let data = Data([
      18, 1,
      0x10, 0x03,
      0xEF, 0x02, 0x01, 64,
      0x34, 0x12,
      0xCD, 0xAB,
      0x00, 0x01,
      1, 2, 3, 1,
    ])

    let descriptor = try MacVirtualMachineUSBDeviceDescriptor(
      id: 42,
      deviceDescriptorData: data
    )

    #expect(descriptor.id == 42)
    #expect(descriptor.vendorID == 0x1234)
    #expect(descriptor.productID == 0xABCD)
    #expect(descriptor.deviceClass == 0xEF)
    #expect(descriptor.deviceSubclass == 0x02)
    #expect(descriptor.deviceProtocol == 0x01)
    #expect(descriptor.vendorProductIdentifier == "1234:ABCD")
  }

  @Test
  func rejectsShortOrWrongDescriptorTypes() {
    #expect(throws: MacVirtualMachineUSBError.invalidDeviceDescriptor) {
      _ = try MacVirtualMachineUSBDeviceDescriptor(
        id: 1,
        deviceDescriptorData: Data(repeating: 0, count: 17)
      )
    }

    var wrongType = Data(repeating: 0, count: 18)
    wrongType[0] = 18
    wrongType[1] = 2
    #expect(throws: MacVirtualMachineUSBError.invalidDeviceDescriptor) {
      _ = try MacVirtualMachineUSBDeviceDescriptor(
        id: 1,
        deviceDescriptorData: wrongType
      )
    }
  }

  @Test
  func snapshotReportsAttachedAndDetachingDevices() {
    let descriptor = MacVirtualMachineUSBDeviceDescriptor(
      id: 9,
      vendorID: 0x05AC,
      productID: 0x1234
    )
    let attached = MacVirtualMachineUSBSnapshot(
      machineID: UUID(),
      devices: [
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: descriptor,
          state: .attached
        )
      ]
    )
    let detaching = MacVirtualMachineUSBSnapshot(
      machineID: UUID(),
      devices: [
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: descriptor,
          state: .detaching
        )
      ]
    )
    let available = MacVirtualMachineUSBSnapshot(
      machineID: UUID(),
      devices: [
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: descriptor,
          state: .available
        )
      ]
    )

    #expect(attached.hasAttachedDevices)
    #expect(detaching.hasAttachedDevices)
    #expect(!available.hasAttachedDevices)
  }

  @Test
  @MainActor
  func unavailableServicePublishesReasonAndRejectsActions() async throws {
    let machineID = UUID()
    let service = UnavailableMacVirtualMachineUSBService(reason: "Unavailable in test")
    let snapshot = service.snapshot(for: machineID)

    #expect(snapshot.machineID == machineID)
    #expect(snapshot.discoveryStatus == .unavailable("Unavailable in test"))
    await #expect(
      throws: MacVirtualMachineUSBError.unavailable("Unavailable in test")
    ) {
      try await service.discover(for: machineID)
    }

    var iterator = service.updates(for: machineID).makeAsyncIterator()
    #expect(await iterator.next() == snapshot)
    #expect(await iterator.next() == nil)
  }
}
