import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineModelsTests {
  @Test
  func resourcesRejectInvalidValues() {
    #expect(throws: VirtualMachineModelError.invalidCPUCount) {
      try VirtualMachineResources(
        cpuCount: 0,
        memoryBytes: VirtualMachineResources.bytesPerGiB,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB
      )
    }

    #expect(throws: VirtualMachineModelError.insufficientMemory) {
      try VirtualMachineResources(
        cpuCount: 2,
        memoryBytes: VirtualMachineResources.bytesPerGiB - 1,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB
      )
    }

    #expect(throws: VirtualMachineModelError.insufficientDisk) {
      try VirtualMachineResources(
        cpuCount: 2,
        memoryBytes: VirtualMachineResources.bytesPerGiB,
        diskBytes: 8 * VirtualMachineResources.bytesPerGiB - 1
      )
    }
  }

  @Test
  func manifestTrimsAndPreservesStableIdentity() throws {
    let identifier = UUID()
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )

    let manifest = try VirtualMachineManifest(
      id: identifier,
      name: "  Developer macOS  ",
      guest: .macOS,
      resources: resources
    )

    #expect(manifest.id == identifier)
    #expect(manifest.name == "Developer macOS")
    #expect(manifest.schemaVersion == VirtualMachineManifest.currentSchemaVersion)
    #expect(manifest.diskImagePath == "Disk.img")
    #expect(manifest.diskImageFormat == .raw)
    #expect(manifest.effectiveDiskImageFormat == .raw)
  }

  @Test
  func renameTrimsAndUpdatesOnlyMutableMetadata() throws {
    let identifier = UUID()
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      id: identifier,
      name: "Before",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    let renamedAt = Date(timeIntervalSince1970: 1_000)

    let changed = try manifest.rename(
      to: "  After  ",
      updatedAt: renamedAt
    )

    #expect(changed)
    #expect(manifest.name == "After")
    #expect(manifest.updatedAt == renamedAt)
    #expect(manifest.id == identifier)
    #expect(manifest.resources == resources)

    let changedAgain = try manifest.rename(
      to: "After",
      updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    #expect(!changedAgain)
    #expect(manifest.updatedAt == renamedAt)

    #expect(throws: VirtualMachineModelError.emptyName) {
      try manifest.rename(to: "   ")
    }
    #expect(manifest.name == "After")
  }

  @Test
  func diskGrowthUpdatesOnlyCapacityAndRejectsShrink() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Growth",
      guest: .linux,
      installState: .stopped,
      resources: resources
    )
    let grownAt = Date(timeIntervalSince1970: 1_000)
    let targetBytes = 72 * VirtualMachineResources.bytesPerGiB

    #expect(try manifest.growDisk(to: targetBytes, updatedAt: grownAt))
    #expect(manifest.resources.diskBytes == targetBytes)
    #expect(manifest.resources.cpuCount == resources.cpuCount)
    #expect(manifest.resources.memoryBytes == resources.memoryBytes)
    #expect(manifest.updatedAt == grownAt)

    #expect(
      try !manifest.growDisk(
        to: targetBytes,
        updatedAt: Date(timeIntervalSince1970: 2_000)
      )
    )
    #expect(manifest.updatedAt == grownAt)
    #expect(throws: VirtualMachineDiskImageResizeError.self) {
      try manifest.growDisk(to: resources.diskBytes)
    }
    #expect(manifest.resources.diskBytes == targetBytes)
  }

  @Test
  func clonePreservesExplicitASIFFormat() throws {
    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var source = try VirtualMachineManifest(
      name: "ASIF Source",
      guest: .macOS,
      installState: .stopped,
      resources: resources
    )
    source.markDiskImageReplaced(to: "Installed/Disk.asif", format: .asif)
    source.audioConfiguration = MacVirtualMachineAudioConfiguration(
      revision: 2,
      isMicrophoneEnabled: true
    )
    source.macOSMinimumCPUCount = 2
    source.macOSMinimumMemoryBytes = 4 * VirtualMachineResources.bytesPerGiB

    let clone = try VirtualMachineManifest(cloning: source, name: "ASIF Clone")

    #expect(clone.diskImagePath == "Installed/Disk.asif")
    #expect(clone.diskImageFormat == .asif)
    #expect(clone.effectiveDiskImageFormat == .asif)
    #expect(clone.audioConfiguration == nil)
    #expect(clone.effectiveAudioConfiguration == .disconnected)
    #expect(clone.macOSMinimumCPUCount == 2)
    #expect(
      clone.macOSMinimumMemoryBytes
        == 4 * VirtualMachineResources.bytesPerGiB
    )
  }
}
