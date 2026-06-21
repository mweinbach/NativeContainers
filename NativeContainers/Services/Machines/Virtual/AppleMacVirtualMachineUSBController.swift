import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

@available(macOS 27.0, *)
@MainActor
final class AppleMacVirtualMachineUSBController: NSObject,
  MacVirtualMachineUSBControlling,
  @preconcurrency VZUSBController.Delegate
{
  private struct Attachment {
    let accessory: AppleMacVirtualMachineUSBAccessory
    let device: VZUSBPassthroughDevice
  }

  var eventHandler: MacVirtualMachineUSBControllerEventHandler?

  var attachedDeviceIDs: Set<UInt64> {
    Set(attachments.keys)
  }

  private let controller: VZUSBController
  private var attachments: [UInt64: Attachment] = [:]

  init(virtualMachine: VZVirtualMachine) throws {
    guard let controller = virtualMachine.usbControllers.first else {
      throw MacVirtualMachineUSBError.controllerUnavailable
    }
    self.controller = controller
    super.init()
    controller.delegate = self
  }

  func attach(_ accessory: any MacVirtualMachineUSBAccessory) async throws {
    guard let accessory = accessory as? AppleMacVirtualMachineUSBAccessory else {
      throw MacVirtualMachineUSBError.incompatibleAccessory
    }
    let identifier = accessory.descriptor.id
    guard attachments[identifier] == nil else {
      throw MacVirtualMachineUSBError.alreadyAttached(identifier)
    }

    let configuration = VZUSBPassthroughDeviceConfiguration(
      device: accessory.accessory
    )
    let device = try VZUSBPassthroughDevice(configuration: configuration)
    try await attach(device)
    attachments[identifier] = Attachment(
      accessory: accessory,
      device: device
    )
  }

  func detach(deviceID: UInt64) async throws {
    guard let attachment = attachments[deviceID] else {
      throw MacVirtualMachineUSBError.notAttached(deviceID)
    }
    try await detach(attachment.device)
    attachments[deviceID] = nil
  }

  func close() {
    controller.delegate = nil
    eventHandler = nil
    attachments.removeAll()
  }

  func usbController(
    _ usbController: VZUSBController,
    usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice
  ) {
    guard
      let identifier = attachments.first(where: {
        $0.value.device === device
      })?.key
    else {
      return
    }
    attachments[identifier] = nil
    eventHandler?(.disconnected(identifier))
  }

  private func attach(_ device: VZUSBPassthroughDevice) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      controller.attach(device: device) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func detach(_ device: VZUSBPassthroughDevice) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      controller.detach(device: device) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
