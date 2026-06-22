import Testing

@testable import NativeContainers

struct VirtualMachineMemoryBalloonModelsTests {
  @Test
  func exposesStableValidatedPresetTargets() throws {
    let gibibyte = VirtualMachineResources.bytesPerGiB
    let snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: 8 * gibibyte,
      minimumTargetMemoryBytes: 2 * gibibyte,
      targetMemoryBytes: 8 * gibibyte
    )

    try snapshot.validate()

    #expect(
      snapshot.targetOptions
        == [
          VirtualMachineMemoryBalloonTargetOption(
            kind: .full,
            memoryBytes: 8 * gibibyte
          ),
          VirtualMachineMemoryBalloonTargetOption(
            kind: .threeQuarters,
            memoryBytes: 6 * gibibyte
          ),
          VirtualMachineMemoryBalloonTargetOption(
            kind: .half,
            memoryBytes: 4 * gibibyte
          ),
          VirtualMachineMemoryBalloonTargetOption(
            kind: .minimum,
            memoryBytes: 2 * gibibyte
          ),
        ]
    )
    #expect(!snapshot.isRequestingReclamation)
    #expect(snapshot.canRequestAnotherTarget)
  }

  @Test
  func skipsPercentagePresetsBelowTheGuestMinimum() throws {
    let gibibyte = VirtualMachineResources.bytesPerGiB
    let snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: 8 * gibibyte,
      minimumTargetMemoryBytes: 7 * gibibyte,
      targetMemoryBytes: 7 * gibibyte
    )

    try snapshot.validate()

    #expect(
      snapshot.targetOptions
        == [
          VirtualMachineMemoryBalloonTargetOption(
            kind: .full,
            memoryBytes: 8 * gibibyte
          ),
          VirtualMachineMemoryBalloonTargetOption(
            kind: .minimum,
            memoryBytes: 7 * gibibyte
          ),
        ]
    )
    #expect(snapshot.isRequestingReclamation)
  }

  @Test
  func validatesAlignmentAndConfiguredRange() {
    let gibibyte = VirtualMachineResources.bytesPerGiB
    let snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: 8 * gibibyte,
      minimumTargetMemoryBytes: 2 * gibibyte,
      targetMemoryBytes: 8 * gibibyte
    )

    #expect(
      throws:
        VirtualMachineMemoryBalloonError.targetMustUseWholeMebibytes
    ) {
      try snapshot.validateTarget(3 * gibibyte + 1)
    }
    #expect(
      throws:
        VirtualMachineMemoryBalloonError.targetOutsideRange(
          minimum: 2 * gibibyte,
          maximum: 8 * gibibyte
        )
    ) {
      try snapshot.validateTarget(gibibyte)
    }
  }

  @Test
  func rejectsAnInvertedConfiguration() {
    let gibibyte = VirtualMachineResources.bytesPerGiB
    let snapshot = VirtualMachineMemoryBalloonSnapshot(
      configuredMemoryBytes: 4 * gibibyte,
      minimumTargetMemoryBytes: 8 * gibibyte,
      targetMemoryBytes: 4 * gibibyte
    )

    #expect(
      throws: VirtualMachineMemoryBalloonError.invalidConfiguration
    ) {
      try snapshot.validate()
    }
  }
}
