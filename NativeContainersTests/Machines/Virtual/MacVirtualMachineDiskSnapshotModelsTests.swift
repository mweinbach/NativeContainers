import Foundation
import Testing

@testable import NativeContainers

@Suite("macOS virtual machine disk snapshot models")
struct MacVirtualMachineDiskSnapshotModelsTests {
  @Test
  func creationBuildsCanonicalLinearHistory() throws {
    let date = Date(timeIntervalSince1970: 123)
    let snapshotID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let layerID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    let mutation = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(
        named: "  Before SDK Update  ",
        snapshotID: snapshotID,
        layerID: layerID,
        at: date
      )

    #expect(mutation.configuration.revision == 1)
    #expect(mutation.configuration.snapshots.count == 1)
    #expect(mutation.configuration.layers.count == 1)
    #expect(mutation.configuration.snapshots[0].name == "Before SDK Update")
    #expect(mutation.configuration.snapshots[0].capturedLayerCount == 0)
    #expect(mutation.configuration.activeLayer == mutation.createdLayer)
    #expect(
      mutation.createdLayer.relativePath
        == "Snapshots/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.asif"
    )
    #expect(mutation.retiredLayers.isEmpty)
  }

  @Test
  func restorePrunesNewerHistoryAndReturnsRetiredLayers() throws {
    let first = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(
        named: "Clean Install",
        snapshotID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        layerID: UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!
      )
    let second = try first.configuration.creatingSnapshot(
      named: "Configured",
      snapshotID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      layerID: UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222")!
    )
    let third = try second.configuration.creatingSnapshot(
      named: "Experimental",
      snapshotID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
      layerID: UUID(uuidString: "CCCCCCCC-3333-3333-3333-333333333333")!
    )

    let restored = try third.configuration.restoring(
      snapshotID: second.configuration.snapshots[1].id,
      layerID: UUID(uuidString: "DDDDDDDD-4444-4444-4444-444444444444")!
    )

    #expect(restored.configuration.revision == 4)
    #expect(restored.configuration.snapshots.map(\.name) == ["Clean Install", "Configured"])
    #expect(
      restored.configuration.layers.map(\.id)
        == [
          first.createdLayer.id,
          UUID(uuidString: "DDDDDDDD-4444-4444-4444-444444444444")!,
        ]
    )
    #expect(
      restored.retiredLayers.map(\.id)
        == [second.createdLayer.id, third.createdLayer.id]
    )
  }

  @Test
  func namesAndHistoryBoundsAreEnforced() throws {
    #expect(throws: MacVirtualMachineDiskSnapshotError.invalidName) {
      _ = try MacVirtualMachineDiskSnapshotConfiguration.empty
        .creatingSnapshot(named: "   ")
    }

    let first = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Release")
    #expect(
      throws: MacVirtualMachineDiskSnapshotError.duplicateName("rélease")
    ) {
      _ = try first.configuration.creatingSnapshot(named: "rélease")
    }

    var configuration = MacVirtualMachineDiskSnapshotConfiguration.empty
    for index in 0..<MacVirtualMachineDiskSnapshotConfiguration.maximumSnapshotCount {
      configuration = try configuration.creatingSnapshot(
        named: "Snapshot \(index)"
      ).configuration
    }
    #expect(
      throws: MacVirtualMachineDiskSnapshotError.maximumSnapshotCount(
        MacVirtualMachineDiskSnapshotConfiguration.maximumSnapshotCount
      )
    ) {
      _ = try configuration.creatingSnapshot(named: "One too many")
    }
  }

  @Test
  func decodingRejectsNonLinearHistory() throws {
    let valid = try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Valid").configuration
    let encoded = try JSONEncoder().encode(valid)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["layers"] = []
    let corrupted = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MacVirtualMachineDiskSnapshotError.invalidConfiguration(
      "snapshot and layer counts must match within the supported limit"
    )) {
      _ = try JSONDecoder().decode(
        MacVirtualMachineDiskSnapshotConfiguration.self,
        from: corrupted
      )
    }
  }

  @Test
  func cloneAndPortableTransferPreserveBundleLocalSnapshotHistory() throws {
    var source = try makeSnapshotManifest()
    source.macOSDiskSnapshotConfiguration =
      try MacVirtualMachineDiskSnapshotConfiguration.empty
      .creatingSnapshot(named: "Portable").configuration

    let clone = try VirtualMachineManifest(
      cloning: source,
      name: "Snapshot Clone"
    )
    let portable = source.portableRepresentation()

    #expect(
      clone.macOSDiskSnapshotConfiguration
        == source.macOSDiskSnapshotConfiguration
    )
    #expect(
      portable.macOSDiskSnapshotConfiguration
        == source.macOSDiskSnapshotConfiguration
    )
  }
}

private func makeSnapshotManifest() throws -> VirtualMachineManifest {
  try VirtualMachineManifest(
    name: "Snapshot VM",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
}
