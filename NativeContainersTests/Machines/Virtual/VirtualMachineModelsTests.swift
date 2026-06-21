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
    source.markDiskImageMigrated(to: "Installed/Disk.asif", format: .asif)

    let clone = try VirtualMachineManifest(cloning: source, name: "ASIF Clone")

    #expect(clone.diskImagePath == "Installed/Disk.asif")
    #expect(clone.diskImageFormat == .asif)
    #expect(clone.effectiveDiskImageFormat == .asif)
  }
}
