import AccessoryAccess
import Foundation

@available(macOS 27.0, *)
final class AppleMacVirtualMachineUSBAccessory: MacVirtualMachineUSBAccessory {
  let descriptor: MacVirtualMachineUSBDeviceDescriptor
  let accessory: AAUSBAccessory

  init(accessory: AAUSBAccessory) throws {
    self.accessory = accessory
    descriptor = try MacVirtualMachineUSBDeviceDescriptor(
      id: accessory.registryID,
      deviceDescriptorData: accessory.deviceDescriptorData
    )
  }
}

@available(macOS 27.0, *)
@MainActor
final class AppleMacVirtualMachineUSBAccessoryDiscovery: NSObject,
  MacVirtualMachineUSBAccessoryDiscovering,
  AAUSBAccessoryListener
{
  var eventHandler: MacVirtualMachineUSBAccessoryEventHandler?

  private let manager: AAUSBAccessoryManager
  private var isRegistered = false

  init(manager: AAUSBAccessoryManager = .shared) {
    self.manager = manager
  }

  func start() async throws -> [any MacVirtualMachineUSBAccessory] {
    guard !isRegistered else { return [] }

    return try await withCheckedThrowingContinuation { continuation in
      manager.registerListener(
        self,
        matchingCriteria: []
      ) { [weak self] accessories, error in
        Task { @MainActor in
          guard let self else {
            continuation.resume(returning: [])
            return
          }
          if let error {
            continuation.resume(throwing: error)
            return
          }

          self.isRegistered = true
          let connected = accessories.compactMap {
            try? AppleMacVirtualMachineUSBAccessory(accessory: $0)
          }
          continuation.resume(returning: connected)
        }
      }
    }
  }

  func stop() async {
    guard isRegistered else { return }

    await withCheckedContinuation { continuation in
      manager.unregisterListener(self) { [weak self] in
        Task { @MainActor in
          self?.isRegistered = false
          continuation.resume()
        }
      }
    }
  }

  nonisolated func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
    guard let accessory = try? AppleMacVirtualMachineUSBAccessory(accessory: usbAccessory) else {
      return
    }
    Task { @MainActor [weak self] in
      self?.eventHandler?(.connected(accessory))
    }
  }

  nonisolated func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
    let identifier = usbAccessory.registryID
    Task { @MainActor [weak self] in
      self?.eventHandler?(.disconnected(identifier))
    }
  }
}
