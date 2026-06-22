import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

#if arch(arm64)
  @Suite("Apple virtual machine snapshot disk stack")
  @MainActor
  struct AppleVirtualMachineDiskSnapshotStackTests {
    @Test
    func descriptorAndWritableAttachmentUseCompleteOverlayStack() throws {
      guard #available(macOS 27.0, *) else { return }
      let rootURL = FileManager.default.temporaryDirectory.appending(
        path: "NativeContainers-Disk-Stack-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let bundleURL = rootURL.appending(
        path: "Machine.nativevm",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: bundleURL,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: rootURL) }

      let baseURL = bundleURL.appending(path: "Disk.img")
      try Data(count: 4_096).write(to: baseURL)
      let layerStore = AppleMacVirtualMachineDiskSnapshotLayerStore()
      let first = try MacVirtualMachineDiskSnapshotConfiguration.empty
        .creatingSnapshot(named: "Base")
      let firstURL = try layerStore.createLayer(
        first.createdLayer,
        baseURL: baseURL,
        retainedLayerURLs: [],
        targetLogicalBytes: 4_096,
        in: bundleURL
      )
      let second = try first.configuration.creatingSnapshot(
        named: "Configured"
      )
      let secondURL = try layerStore.createLayer(
        second.createdLayer,
        baseURL: baseURL,
        retainedLayerURLs: [firstURL],
        targetLogicalBytes: 4_096,
        in: bundleURL
      )

      var manifest = try VirtualMachineManifest(
        name: "Stack Test",
        guest: .macOS,
        installState: .stopped,
        resources: VirtualMachineResources(
          cpuCount: 4,
          memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
          diskBytes: 8 * VirtualMachineResources.bytesPerGiB
        )
      )
      manifest.macOSDiskSnapshotConfiguration = second.configuration
      let machine = ResolvedMacVirtualMachine(
        manifest: manifest,
        bundleURL: bundleURL,
        diskImageURL: baseURL,
        diskSnapshotLayerURLs: [firstURL, secondURL],
        auxiliaryStorageURL: bundleURL.appending(path: "AuxiliaryStorage"),
        hardwareModelURL: bundleURL.appending(path: "HardwareModel"),
        machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier")
      )
      let service = AppleVirtualMachineDiskImageService()

      let descriptor = try service.descriptor(for: machine)
      #expect(descriptor.format == .raw)
      #expect(descriptor.logicalBytes == 4_096)
      #expect(descriptor.layerType == .overlay)

      do {
        let attachment = try service.makeWritableAttachment(for: machine)
        #expect(attachment is VZDiskImageStorageDeviceAttachment)
        withExtendedLifetime(attachment) {}
      }
    }
  }
#endif
