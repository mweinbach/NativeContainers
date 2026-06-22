@testable import NativeContainers

@MainActor
final class TestVirtualMachineMemoryBalloonController:
  VirtualMachineMemoryBalloonControlling
{
  private(set) var snapshot: VirtualMachineMemoryBalloonSnapshot
  private(set) var requestedTargets: [UInt64] = []

  init(
    configuredMemoryBytes: UInt64,
    minimumTargetMemoryBytes: UInt64
  ) {
    snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: configuredMemoryBytes,
      minimumTargetMemoryBytes: minimumTargetMemoryBytes,
      targetMemoryBytes: configuredMemoryBytes
    )
  }

  func requestTargetMemory(_ memoryBytes: UInt64) throws {
    try snapshot.validateTarget(memoryBytes)
    requestedTargets.append(memoryBytes)
    snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: snapshot.configuredMemoryBytes,
      minimumTargetMemoryBytes: snapshot.minimumTargetMemoryBytes,
      targetMemoryBytes: memoryBytes
    )
  }
}
