import ContainerAPIClient
import ContainerXPC
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Storage usage services")
struct StorageUsageServiceTests {
  @Test
  func appleRuntimeClientUsesDiskUsageRouteAndMapsValidatedPayload() async throws {
    let stats = DiskUsageStats(
      images: ResourceUsage(
        total: 8,
        active: 3,
        sizeInBytes: 2_400,
        reclaimable: 600
      ),
      containers: ResourceUsage(
        total: 4,
        active: 2,
        sizeInBytes: 900,
        reclaimable: 200
      ),
      volumes: ResourceUsage(
        total: 2,
        active: 2,
        sizeInBytes: 300,
        reclaimable: 0
      )
    )
    let response = XPCMessage(route: "reply")
    response.set(
      key: .diskUsageStats,
      value: try JSONEncoder().encode(stats)
    )
    let sender = StaticStorageXPCSender(response: response)
    let capturedAt = Date(timeIntervalSince1970: 42)
    let service = AppleRuntimeStorageUsageService(
      reader: AppleRuntimeDiskUsageClient(requestSender: sender),
      now: { capturedAt }
    )

    let usage = try await service.loadAppleRuntimeStorageUsage()

    #expect(usage.capturedAt == capturedAt)
    #expect(
      usage.images
        == StorageResourceUsage(
          totalCount: 8,
          activeCount: 3,
          allocatedBytes: 2_400,
          reclaimableBytes: 600
        )
    )
    #expect(usage.containers.inactiveCount == 2)
    #expect(usage.volumes.retainedBytes == 300)
    #expect(usage.totalAllocatedBytes == 3_600)
    #expect(await sender.routes == [XPCRoute.systemDiskUsage.rawValue])
  }

  @Test
  func appleRuntimeClientRejectsMissingMalformedAndInvalidPayloads() async throws {
    let missing = AppleRuntimeDiskUsageClient(
      requestSender: StaticStorageXPCSender(
        response: XPCMessage(route: "reply")
      )
    )
    await #expect(
      throws: StorageUsageError.invalidRuntimeResponse(
        "the disk-usage payload is missing"
      )
    ) {
      _ = try await missing.readDiskUsage()
    }

    let malformedResponse = XPCMessage(route: "reply")
    malformedResponse.set(key: .diskUsageStats, value: Data("not-json".utf8))
    let malformed = AppleRuntimeDiskUsageClient(
      requestSender: StaticStorageXPCSender(response: malformedResponse)
    )
    await #expect(
      throws: StorageUsageError.invalidRuntimeResponse(
        "the disk-usage payload is malformed"
      )
    ) {
      _ = try await malformed.readDiskUsage()
    }

    let invalidStats = DiskUsageStats(
      images: ResourceUsage(
        total: 1,
        active: 2,
        sizeInBytes: 100,
        reclaimable: 0
      ),
      containers: ResourceUsage(
        total: 0,
        active: 0,
        sizeInBytes: 0,
        reclaimable: 0
      ),
      volumes: ResourceUsage(
        total: 0,
        active: 0,
        sizeInBytes: 0,
        reclaimable: 0
      )
    )
    let invalidResponse = XPCMessage(route: "reply")
    invalidResponse.set(
      key: .diskUsageStats,
      value: try JSONEncoder().encode(invalidStats)
    )
    let invalid = AppleRuntimeDiskUsageClient(
      requestSender: StaticStorageXPCSender(response: invalidResponse)
    )
    await #expect(
      throws: StorageUsageError.invalidRuntimeResponse(
        "images has an invalid active count"
      )
    ) {
      _ = try await invalid.readDiskUsage()
    }
  }

  @Test
  func vmLibraryScanAccountsForSparseHiddenLinkedAndNonRegularEntries() async throws {
    let root = temporaryRoot()
    let outside = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).data")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try Data(repeating: 7, count: 1_048_576).write(to: outside)

    let manifest = try makeManifest(name: "Storage Lab")
    let bundle =
      root
      .appending(
        path: manifest.id.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    try FileManager.default.createDirectory(
      at: bundle,
      withIntermediateDirectories: true
    )

    let disk = bundle.appending(path: manifest.diskImagePath)
    #expect(FileManager.default.createFile(atPath: disk.path, contents: nil))
    let diskHandle = try FileHandle(forWritingTo: disk)
    try diskHandle.truncate(atOffset: 64 * 1_024 * 1_024)
    try diskHandle.close()

    let payload = bundle.appending(path: "payload.data")
    try Data(repeating: 1, count: 8_192).write(to: payload)
    let hardLink = bundle.appending(path: "payload-link.data")
    #expect(Darwin.link(payload.path, hardLink.path) == 0)

    try FileManager.default.createSymbolicLink(
      at: bundle.appending(path: "outside-link"),
      withDestinationURL: outside
    )
    let fifo = bundle.appending(path: "control.fifo")
    #expect(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    let savedState = bundle.appending(
      path: MacVirtualMachineSavedStateStore.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: savedState,
      withIntermediateDirectories: true
    )
    try Data(repeating: 2, count: 4_096).write(
      to: savedState.appending(path: "state.data")
    )

    try Data(repeating: 3, count: 4_096).write(
      to: root.appending(path: ".import-partial")
    )

    let inventory = VirtualMachineStorageInventory(
      rootURL: root,
      targets: [
        VirtualMachineStorageTarget(
          manifest: manifest,
          bundleURL: bundle
        )
      ]
    )
    let capturedAt = Date(timeIntervalSince1970: 84)
    let service = VirtualMachineStorageUsageService(
      inventory: StaticVirtualMachineStorageInventory(inventory: inventory),
      now: { capturedAt }
    )

    let summary = try await service.loadVirtualMachineStorageUsage()
    let machine = try #require(summary.machines.first)

    #expect(summary.capturedAt == capturedAt)
    #expect(summary.discoveredMachineCount == 1)
    #expect(summary.machines.count == 1)
    #expect(machine.diskLogicalBytes == 64 * 1_024 * 1_024)
    #expect(machine.diskAllocatedBytes < machine.diskLogicalBytes)
    #expect(machine.hardLinkCount == 1)
    #expect(machine.nonRegularEntryCount >= 2)
    #expect(machine.savedStateAllocatedBytes > 0)
    #expect(machine.bundleLogicalBytes < 65 * 1_024 * 1_024)
    #expect(summary.libraryLogicalBytes == machine.bundleLogicalBytes + 4_096)
    #expect(summary.unattributedAllocatedBytes > 0)
    #expect(summary.hasApproximateMeasurements)
    #expect(summary.issues.isEmpty)
  }

  @Test
  func cancellingVMStorageLoadStopsDetachedMeasurement() async {
    let measurer = CancellationObservingStorageMeasurer()
    let service = VirtualMachineStorageUsageService(
      inventory: StaticVirtualMachineStorageInventory(
        inventory: VirtualMachineStorageInventory(
          rootURL: URL(filePath: "/tmp/unused"),
          targets: []
        )
      ),
      measurer: measurer
    )
    let operation = Task {
      try await service.loadVirtualMachineStorageUsage()
    }
    while !measurer.hasStarted {
      await Task.yield()
    }

    operation.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await operation.value
    }
    #expect(measurer.didObserveCancellation)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  private func makeManifest(name: String) throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: name,
      guest: .macOS,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}

private actor StaticStorageXPCSender: AppleXPCRequestSending {
  let response: XPCMessage
  private(set) var routes: [String] = []

  init(response: XPCMessage) {
    self.response = response
  }

  func send(
    _ message: XPCMessage,
    operation: String
  ) async throws -> XPCMessage {
    if let route = message.string(key: XPCMessage.routeKey) {
      routes.append(route)
    }
    return response
  }
}

private struct StaticVirtualMachineStorageInventory:
  VirtualMachineStorageInventoryLoading
{
  let inventory: VirtualMachineStorageInventory

  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
  {
    inventory
  }
}

private final class CancellationObservingStorageMeasurer:
  VirtualMachineLibraryStorageMeasuring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var started = false
  private var observedCancellation = false

  var hasStarted: Bool {
    lock.withLock { started }
  }

  var didObserveCancellation: Bool {
    lock.withLock { observedCancellation }
  }

  func measureStorage(
    in inventory: VirtualMachineStorageInventory
  ) throws -> VirtualMachineLibraryStorageMeasurement {
    lock.withLock {
      started = true
    }
    while true {
      do {
        try Task.checkCancellation()
      } catch {
        lock.withLock {
          observedCancellation = true
        }
        throw error
      }
      Thread.sleep(forTimeInterval: 0.001)
    }
  }
}
