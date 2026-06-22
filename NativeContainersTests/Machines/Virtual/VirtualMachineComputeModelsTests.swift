import Testing

@testable import NativeContainers

@Suite("Virtual machine compute models")
struct VirtualMachineComputeModelsTests {
  @Test
  func guestMinimumsNarrowPlatformLimitsWithoutChangingMaximums() throws {
    let limits = try platformLimits().applyingGuestMinimum(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB
    )

    #expect(limits.minimumCPUCount == 4)
    #expect(limits.maximumCPUCount == 12)
    #expect(
      limits.minimumMemoryBytes
        == 8 * VirtualMachineResources.bytesPerGiB
    )
    #expect(
      limits.maximumMemoryBytes
        == 64 * VirtualMachineResources.bytesPerGiB
    )
  }

  @Test
  func validationRejectsValuesOutsideAppleAndGuestBounds() throws {
    let limits = try platformLimits().applyingGuestMinimum(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB
    )

    #expect(
      throws: VirtualMachineComputeError.invalidCPUCount(
        minimum: 4,
        maximum: 12
      )
    ) {
      try limits.validate(
        VirtualMachineComputeConfiguration(
          cpuCount: 2,
          memoryBytes: 8 * VirtualMachineResources.bytesPerGiB
        )
      )
    }
    #expect(
      throws: VirtualMachineComputeError.invalidMemorySize(
        minimum: 8 * VirtualMachineResources.bytesPerGiB,
        maximum: 64 * VirtualMachineResources.bytesPerGiB
      )
    ) {
      try limits.validate(
        VirtualMachineComputeConfiguration(
          cpuCount: 4,
          memoryBytes: 4 * VirtualMachineResources.bytesPerGiB
        )
      )
    }
    #expect(throws: VirtualMachineComputeError.memoryMustBeMegabyteAligned) {
      try limits.validate(
        VirtualMachineComputeConfiguration(
          cpuCount: 4,
          memoryBytes: 8 * VirtualMachineResources.bytesPerGiB + 1
        )
      )
    }
  }

  @Test
  func legacyMacManifestUsesCurrentAllocationAsSafeFloor() throws {
    let manifest = try VirtualMachineManifest(
      name: "Legacy Mac",
      guest: .macOS,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 6,
        memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )

    let state = VirtualMachineComputeState(manifest: manifest)
    let snapshot = try state.snapshot(platformLimits: platformLimits())

    #expect(snapshot.limits.minimumCPUCount == 6)
    #expect(
      snapshot.limits.minimumMemoryBytes
        == 12 * VirtualMachineResources.bytesPerGiB
    )
  }

  @Test
  func partialMacGuestRequirementsAreRejected() throws {
    var manifest = try macManifest()
    manifest.macOSMinimumCPUCount = 4

    #expect(
      throws: VirtualMachineComputeError.invalidPersistedGuestRequirements
    ) {
      try VirtualMachineComputeState.validatePersistedRequirements(
        in: manifest
      )
    }
  }

  @Test
  func macGuestRequirementsMustFitThePersistedAllocation() throws {
    var manifest = try macManifest()
    manifest.macOSMinimumCPUCount = manifest.resources.cpuCount + 1
    manifest.macOSMinimumMemoryBytes = manifest.resources.memoryBytes

    #expect(
      throws: VirtualMachineComputeError.invalidPersistedGuestRequirements
    ) {
      _ = try VirtualMachineComputeState(manifest: manifest)
        .snapshot(platformLimits: platformLimits())
    }

    manifest.macOSMinimumCPUCount = manifest.resources.cpuCount
    manifest.macOSMinimumMemoryBytes =
      manifest.resources.memoryBytes - 1

    #expect(
      throws: VirtualMachineComputeError.invalidPersistedGuestRequirements
    ) {
      try VirtualMachineComputeState.validatePersistedRequirements(
        in: manifest
      )
    }
  }

  @Test
  func linuxRejectsMacGuestRequirementResidue() throws {
    var manifest = try VirtualMachineManifest(
      name: "Linux with Mac residue",
      guest: .linux,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
    manifest.macOSMinimumCPUCount = 2
    manifest.macOSMinimumMemoryBytes =
      4 * VirtualMachineResources.bytesPerGiB

    #expect(
      throws: VirtualMachineComputeError.invalidPersistedGuestRequirements
    ) {
      try VirtualMachineComputeState.validatePersistedRequirements(
        in: manifest
      )
    }
  }

  @Test
  func linuxManifestUsesPlatformFloorAndKeepsDiskCapacity() throws {
    let manifest = try VirtualMachineManifest(
      name: "Linux",
      guest: .linux,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 6,
        memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 96 * VirtualMachineResources.bytesPerGiB
      )
    )

    let snapshot = try VirtualMachineComputeState(manifest: manifest)
      .snapshot(platformLimits: platformLimits())

    #expect(snapshot.limits.minimumCPUCount == 1)
    #expect(
      snapshot.limits.minimumMemoryBytes
        == VirtualMachineResources.bytesPerGiB
    )
    #expect(
      snapshot.diskBytes == 96 * VirtualMachineResources.bytesPerGiB
    )
  }

  private func platformLimits() -> VirtualMachineComputeLimits {
    VirtualMachineComputeLimits(
      minimumCPUCount: 1,
      maximumCPUCount: 12,
      minimumMemoryBytes: VirtualMachineResources.bytesPerGiB,
      maximumMemoryBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  }

  private func macManifest() throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: "Validated Mac",
      guest: .macOS,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 6,
        memoryBytes: 12 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}
