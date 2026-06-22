import Foundation
@preconcurrency import Virtualization

@MainActor
protocol VirtualMachineMemoryBalloonControlling: AnyObject {
  var snapshot: VirtualMachineMemoryBalloonSnapshot { get }

  func requestTargetMemory(_ memoryBytes: UInt64) throws
}

@MainActor
final class AppleVirtualMachineMemoryBalloonController:
  VirtualMachineMemoryBalloonControlling
{
  private let device: VZVirtioTraditionalMemoryBalloonDevice
  private let configuredMemoryBytes: UInt64
  private let minimumTargetMemoryBytes: UInt64

  init(
    virtualMachine: VZVirtualMachine,
    configuredMemoryBytes: UInt64,
    minimumTargetMemoryBytes: UInt64
  ) throws {
    guard virtualMachine.memoryBalloonDevices.count == 1,
      let device = virtualMachine.memoryBalloonDevices.first
        as? VZVirtioTraditionalMemoryBalloonDevice
    else {
      throw VirtualMachineMemoryBalloonError.unavailable
    }

    self.device = device
    self.configuredMemoryBytes = configuredMemoryBytes
    self.minimumTargetMemoryBytes = try Self.alignedMinimum(
      configuredMemoryBytes: configuredMemoryBytes,
      requestedMinimum: minimumTargetMemoryBytes
    )
    try snapshot.validate()
  }

  var snapshot: VirtualMachineMemoryBalloonSnapshot {
    VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: configuredMemoryBytes,
      minimumTargetMemoryBytes: minimumTargetMemoryBytes,
      targetMemoryBytes: device.targetVirtualMachineMemorySize
    )
  }

  func requestTargetMemory(_ memoryBytes: UInt64) throws {
    try snapshot.validateTarget(memoryBytes)
    device.targetVirtualMachineMemorySize = memoryBytes
  }

  private static func alignedMinimum(
    configuredMemoryBytes: UInt64,
    requestedMinimum: UInt64
  ) throws -> UInt64 {
    let alignment = VirtualMachineMemoryBalloonSnapshot.alignmentBytes
    let hostMinimum = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    let minimum = max(requestedMinimum, hostMinimum)
    let remainder = minimum % alignment
    let alignedMinimum: UInt64
    if remainder == 0 {
      alignedMinimum = minimum
    } else {
      let (value, overflowed) = minimum.addingReportingOverflow(
        alignment - remainder
      )
      guard !overflowed else {
        throw VirtualMachineMemoryBalloonError.invalidConfiguration
      }
      alignedMinimum = value
    }
    guard configuredMemoryBytes.isMultiple(of: alignment),
      alignedMinimum <= configuredMemoryBytes
    else {
      throw VirtualMachineMemoryBalloonError.invalidConfiguration
    }
    return alignedMinimum
  }
}
