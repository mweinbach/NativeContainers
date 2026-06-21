import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct AppOwnedBuildCacheStoreTests {
  @Test
  func protocolV5UsesOnlyClosedCacheModes() throws {
    let buildID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let encoder = JSONEncoder()

    for mode in ImageBuildCachePolicy.allCases {
      let request = ContainerBuildWorkerRequest(
        operation: .build,
        build: ContainerBuildWorkerBuildRequest(
          buildID: buildID,
          contextPath: "/private/context",
          dockerfilePath: "/private/context/Dockerfile",
          dockerfileSHA256: "dockerfile",
          contextFingerprint: "context",
          dockerignorePath: nil,
          dockerignoreSHA256: nil,
          tags: [],
          platforms: [.current],
          buildArguments: [],
          labels: [],
          targetStage: "",
          cachePolicy: mode,
          pullLatest: false,
          secretIDs: [],
          allowsTagReplacement: false
        )
      )
      let encoded = try encoder.encode(request)
      let json = try #require(String(data: encoded, encoding: .utf8))
      #expect(!json.contains("type=local"))
      #expect(!json.contains("src="))
      #expect(!json.contains("dest="))
      #expect(!json.contains("nativecontainers-cache-v1"))
      #expect(try JSONDecoder().decode(ContainerBuildWorkerRequest.self, from: encoded) == request)
    }

    #expect(ContainerBuildWorkerRequest.currentProtocolVersion == 5)
    let receipt = ContainerBuildWorkerCacheReceipt(
      mode: .appOwnedLocalV1,
      handoffToken: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
      fingerprintSHA256: String(repeating: "a", count: 64),
      byteCount: 4_096,
      entryCount: 9
    )
    let encodedReceipt = try encoder.encode(receipt)
    let receiptJSON = try #require(String(data: encodedReceipt, encoding: .utf8))
    #expect(!receiptJSON.contains("type=local"))
    #expect(!receiptJSON.contains("src="))
    #expect(!receiptJSON.contains("dest="))
    #expect(!receiptJSON.contains("nativecontainers-cache-v1"))
    #expect(
      try JSONDecoder().decode(ContainerBuildWorkerCacheReceipt.self, from: encodedReceipt)
        == receipt
    )

    let valid = try encoder.encode(
      ContainerBuildWorkerRequest(
        operation: .build,
        build: ContainerBuildWorkerBuildRequest(
          buildID: buildID,
          contextPath: "/private/context",
          dockerfilePath: "/private/context/Dockerfile",
          dockerfileSHA256: "dockerfile",
          contextFingerprint: "context",
          dockerignorePath: nil,
          dockerignoreSHA256: nil,
          tags: [],
          platforms: [.current],
          buildArguments: [],
          labels: [],
          targetStage: "",
          cachePolicy: .builderInternal,
          pullLatest: false,
          secretIDs: [],
          allowsTagReplacement: false
        )
      )
    )
    let unknownMode = try #require(String(data: valid, encoding: .utf8))
      .replacingOccurrences(of: "builderInternal", with: "futureMode")
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        ContainerBuildWorkerRequest.self,
        from: Data(unknownMode.utf8)
      )
    }
  }

  @Test
  func promotesReusesAndResetsOneFixedCacheProfile() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    let firstLease = try await requiredLease(store: store, buildID: firstID)
    #expect(!firstLease.hasImportableCache)
    try writeCacheExport(root: root, buildID: firstID, marker: "first")
    let first = try firstLease.commit()
    #expect(first.byteCount > 0)
    #expect(first.entryCount >= 6)
    #expect(try currentMarker(root: root) == "first")

    let secondLease = try await requiredLease(store: store, buildID: secondID)
    #expect(secondLease.hasImportableCache)
    #expect(try currentMarker(root: root) == "first")
    try writeCacheExport(root: root, buildID: secondID, marker: "second")
    let second = try secondLease.commit()
    #expect(try currentMarker(root: root) == "second")
    #expect(try await store.inspect() == second)

    _ = try await store.reset()
    #expect(try await store.inspect() == nil)
  }

  @Test
  func workerPreparationDoesNotReplaceCurrentUntilHostCommit() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let firstID = UUID(uuidString: "21212121-2121-2121-2121-212121212121")!
    let secondID = UUID(uuidString: "22212121-2121-2121-2121-212121212121")!

    let firstLease = try await requiredLease(store: store, buildID: firstID)
    try writeCacheExport(root: root, buildID: firstID, marker: "stable")
    _ = try firstLease.commit()

    let secondLease = try await requiredLease(store: store, buildID: secondID)
    try writeCacheExport(root: root, buildID: secondID, marker: "prepared")
    let prepared = try secondLease.prepareForHostCommit()
    #expect(try currentMarker(root: root) == "stable")
    #expect(try await store.inspect() != nil)
    let interveningLease = try await requiredLease(store: store, buildID: UUID())
    #expect(interveningLease.hasImportableCache)
    interveningLease.release()

    let committed = try await store.commitPreparedExport(
      buildID: secondID,
      handoffToken: prepared.handoffToken,
      expectedSnapshot: prepared.snapshot,
      expectedFingerprintSHA256: prepared.fingerprintSHA256
    )
    #expect(committed.byteCount == prepared.snapshot.byteCount)
    #expect(committed.entryCount == prepared.snapshot.entryCount)
    #expect(try currentMarker(root: root) == "prepared")
  }

  @Test
  func sameSizedPreparedPayloadMutationIsRejectedAndPreservesCurrent() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let committedID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
    let preparedID = UUID(uuidString: "24242424-2424-2424-2424-242424242424")!

    let committedLease = try await requiredLease(store: store, buildID: committedID)
    try writeCacheExport(root: root, buildID: committedID, marker: "stable")
    _ = try committedLease.commit()

    let preparedLease = try await requiredLease(store: store, buildID: preparedID)
    try writeCacheExport(root: root, buildID: preparedID, marker: "candidate")
    let prepared = try preparedLease.prepareForHostCommit()
    let preparedMarker = preparedExportURL(
      root: root,
      buildID: preparedID,
      handoffToken: prepared.handoffToken
    ).appending(path: "marker.txt", directoryHint: .notDirectory)
    let originalSize = try Data(contentsOf: preparedMarker).count
    let handle = try FileHandle(forWritingTo: preparedMarker)
    try handle.write(contentsOf: Data("tampered!".utf8))
    try handle.synchronize()
    try handle.close()
    let mutatedSize = try Data(contentsOf: preparedMarker).count
    #expect(originalSize == mutatedSize)

    await #expect(throws: AppOwnedBuildCacheStoreError.invalidHandoff) {
      _ = try await store.commitPreparedExport(
        buildID: preparedID,
        handoffToken: prepared.handoffToken,
        expectedSnapshot: prepared.snapshot,
        expectedFingerprintSHA256: prepared.fingerprintSHA256
      )
    }
    #expect(try currentMarker(root: root) == "stable")
    #expect(try await store.inspect() != nil)
  }

  @Test
  func explicitResetInvalidatesPreparedHandoffsAndCommittedCache() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let committedID = UUID(uuidString: "25252525-2525-2525-2525-252525252525")!
    let preparedID = UUID(uuidString: "26262626-2626-2626-2626-262626262626")!

    let committedLease = try await requiredLease(store: store, buildID: committedID)
    try writeCacheExport(root: root, buildID: committedID, marker: "stable")
    _ = try committedLease.commit()

    let preparedLease = try await requiredLease(store: store, buildID: preparedID)
    try writeCacheExport(root: root, buildID: preparedID, marker: "prepared")
    let prepared = try preparedLease.prepareForHostCommit()

    _ = try await store.reset()
    await #expect(throws: AppOwnedBuildCacheStoreError.self) {
      _ = try await store.commitPreparedExport(
        buildID: preparedID,
        handoffToken: prepared.handoffToken,
        expectedSnapshot: prepared.snapshot,
        expectedFingerprintSHA256: prepared.fingerprintSHA256
      )
    }
    #expect(try await store.inspect() == nil)
  }

  @Test
  func failedPromotionPreservesThePreviouslyCommittedCache() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let firstID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let invalidID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    let firstLease = try await requiredLease(store: store, buildID: firstID)
    try writeCacheExport(root: root, buildID: firstID, marker: "stable")
    _ = try firstLease.commit()

    let invalidLease = try await requiredLease(store: store, buildID: invalidID)
    let invalid = cacheExportURL(root: root, buildID: invalidID)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data("invalid".utf8).write(
      to: invalid.appending(path: "index.json", directoryHint: .notDirectory)
    )
    #expect(throws: AppOwnedBuildCacheStoreError.self) {
      _ = try invalidLease.commit()
    }

    #expect(try currentMarker(root: root) == "stable")
    #expect(try await store.inspect() != nil)
  }

  @Test
  func cancellationNeverReplacesTheCurrentCache() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let firstID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let cancelledID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    let firstLease = try await requiredLease(store: store, buildID: firstID)
    try writeCacheExport(root: root, buildID: firstID, marker: "stable")
    _ = try firstLease.commit()

    do {
      let cancelledLease = try await requiredLease(store: store, buildID: cancelledID)
      defer { cancelledLease.release() }
      try writeCacheExport(root: root, buildID: cancelledID, marker: "cancelled")
      throw CancellationError()
    } catch is CancellationError {
      // Expected: releasing an uncommitted lease removes only its staging export.
    }

    #expect(try currentMarker(root: root) == "stable")
    #expect(
      !FileManager.default.fileExists(atPath: cacheExportURL(root: root, buildID: cancelledID).path)
    )
  }

  @Test
  func waitingForTheCrossProcessLeaseIsCancellationResponsive() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let firstLease = try await requiredLease(store: store, buildID: UUID())
    defer { firstLease.release() }

    let waiter = Task {
      try await store.acquireLease(policy: .appOwnedLocalV1, buildID: UUID())
    }
    try await Task.sleep(for: .milliseconds(100))
    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await waiter.value
    }
  }

  @Test
  func cancelledManagementResetCannotDeleteCacheAfterTheLockBecomesAvailable() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let committedID = UUID(uuidString: "68686868-6868-6868-6868-686868686868")!
    let leaseID = UUID(uuidString: "69696969-6969-6969-6969-696969696969")!
    let committedLease = try await requiredLease(store: store, buildID: committedID)
    try writeCacheExport(root: root, buildID: committedID, marker: "stable")
    _ = try committedLease.commit()
    let heldLease = try await requiredLease(store: store, buildID: leaseID)
    let service = AppleAppOwnedBuildCacheService(
      rootLoader: FixedAppOwnedBuildCacheRootLoader(root: root),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )

    let reset = Task { try await service.resetCache() }
    try await Task.sleep(for: .milliseconds(100))
    reset.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await reset.value
    }
    heldLease.release()
    try await Task.sleep(for: .milliseconds(100))

    #expect(try currentMarker(root: root) == "stable")
  }

  @Test
  func nextLeaseRecoversHardExitStagingWithoutTouchingCommittedOrUnrelatedData() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let committedID = UUID(uuidString: "71717171-7171-7171-7171-717171717171")!
    let abandonedID = UUID(uuidString: "72727272-7272-7272-7272-727272727272")!

    let committedLease = try await requiredLease(store: store, buildID: committedID)
    try writeCacheExport(root: root, buildID: committedID, marker: "committed")
    _ = try committedLease.commit()
    try writeCacheExport(root: root, buildID: abandonedID, marker: "abandoned")
    let unrelated = root.appending(path: "other-export", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)

    let recoveryLease = try await requiredLease(store: store, buildID: UUID())
    defer { recoveryLease.release() }

    #expect(
      !FileManager.default.fileExists(atPath: cacheExportURL(root: root, buildID: abandonedID).path)
    )
    #expect(try currentMarker(root: root) == "committed")
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test
  func nextLeaseReclaimsOnlyExpiredPreparedHandoffs() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let committedID = UUID(uuidString: "73737373-7373-7373-7373-737373737373")!
    let expiredID = UUID(uuidString: "74747474-7474-7474-7474-747474747474")!

    let committedLease = try await requiredLease(store: store, buildID: committedID)
    try writeCacheExport(root: root, buildID: committedID, marker: "stable")
    _ = try committedLease.commit()

    let expiredLease = try await requiredLease(store: store, buildID: expiredID)
    try writeCacheExport(root: root, buildID: expiredID, marker: "expired")
    let prepared = try expiredLease.prepareForHostCommit()
    let preparedURL = preparedExportURL(
      root: root,
      buildID: expiredID,
      handoffToken: prepared.handoffToken
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -(48 * 60 * 60))],
      ofItemAtPath: preparedURL.path(percentEncoded: false)
    )

    let recoveryLease = try await requiredLease(store: store, buildID: UUID())
    recoveryLease.release()

    #expect(!FileManager.default.fileExists(atPath: preparedURL.path(percentEncoded: false)))
    #expect(try currentMarker(root: root) == "stable")
  }

  @Test
  func managementServiceInspectsAndResetsOnlyTheAppNamespace() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let buildID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let lease = try await requiredLease(store: store, buildID: buildID)
    try writeCacheExport(root: root, buildID: buildID, marker: "managed")
    let committed = try lease.commit()
    let unrelated = root.appending(path: "unrelated-export", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
    let service = AppleAppOwnedBuildCacheService(
      rootLoader: FixedAppOwnedBuildCacheRootLoader(root: root),
      buildExecutionCoordinator: RuntimeMutationCoordinator()
    )

    #expect(try await service.loadCache() == committed)
    _ = try await service.resetCache()
    #expect(try await service.loadCache() == nil)
    #expect(FileManager.default.fileExists(atPath: unrelated.path(percentEncoded: false)))
  }

  @Test
  func freshMissingBuilderRootInspectsAndResetsAsEmpty() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-missing-builder-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)

    #expect(try await store.inspect() == nil)
    _ = try await store.reset()
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test
  func malformedOwnedCacheRemainsResettable() async throws {
    let root = try makeSharedExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppOwnedBuildCacheStore(sharedExportRoot: root)
    let lease = try await requiredLease(store: store, buildID: UUID())
    lease.release()
    let current = currentCacheURL(root: root)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
    try Data("not-an-oci-cache".utf8).write(
      to: current.appending(path: "index.json", directoryHint: .notDirectory)
    )

    await #expect(throws: AppOwnedBuildCacheStoreError.self) {
      _ = try await store.inspect()
    }
    _ = try await store.reset()
    #expect(try await store.inspect() == nil)
  }

  @MainActor
  @Test
  func observableModelLoadsAndResetsThroughTheFocusedService() async {
    let service = RecordingAppOwnedBuildCacheService(
      snapshot: AppOwnedBuildCacheSnapshot(byteCount: 4_096, entryCount: 3),
      resetReceipt: AppOwnedBuildCacheResetReceipt(
        maintenanceWarning: "Retired cache cleanup is pending."
      )
    )
    let model = AppOwnedBuildCacheModel(service: service)

    await model.load()
    #expect(model.snapshot?.byteCount == 4_096)
    #expect(await model.reset())
    #expect(model.snapshot == nil)
    #expect(model.maintenanceWarning == "Retired cache cleanup is pending.")
    #expect(await service.resetCount == 1)
  }
}

private actor RecordingAppOwnedBuildCacheService: AppOwnedBuildCacheManaging {
  private var snapshot: AppOwnedBuildCacheSnapshot?
  private let resetReceipt: AppOwnedBuildCacheResetReceipt
  private(set) var resetCount = 0

  init(
    snapshot: AppOwnedBuildCacheSnapshot?,
    resetReceipt: AppOwnedBuildCacheResetReceipt = AppOwnedBuildCacheResetReceipt()
  ) {
    self.snapshot = snapshot
    self.resetReceipt = resetReceipt
  }

  func loadCache() async throws -> AppOwnedBuildCacheSnapshot? { snapshot }

  func resetCache() async throws -> AppOwnedBuildCacheResetReceipt {
    resetCount += 1
    snapshot = nil
    return resetReceipt
  }
}

private struct FixedAppOwnedBuildCacheRootLoader: AppOwnedBuildCacheRootLoading {
  let root: URL

  func loadSharedExportRoot() async throws -> URL { root }
}

private func requiredLease(
  store: AppOwnedBuildCacheStore,
  buildID: UUID
) async throws -> AppOwnedBuildCacheLease {
  let acquired = try await store.acquireLease(
    policy: .appOwnedLocalV1,
    buildID: buildID
  )
  return try #require(acquired)
}

private func makeSharedExportRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "nativecontainers-cache-store-\(UUID().uuidString.lowercased())",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o755]
  )
  guard Darwin.chmod(root.path(percentEncoded: false), 0o755) == 0 else {
    throw AppOwnedBuildCacheStoreError.ioFailure(
      operation: "prepare test root",
      path: root.path(percentEncoded: false),
      code: errno
    )
  }
  return root
}

private func writeCacheExport(
  root: URL,
  buildID: UUID,
  marker: String
) throws {
  let export = cacheExportURL(root: root, buildID: buildID)
  let blobs =
    export
    .appending(path: "blobs", directoryHint: .isDirectory)
    .appending(path: "sha256", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

  let descriptor = Data("descriptor-\(marker)".utf8)
  let digest = sha256(descriptor)
  try descriptor.write(
    to: blobs.appending(path: digest, directoryHint: .notDirectory)
  )
  try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(
    to: export.appending(path: "oci-layout", directoryHint: .notDirectory)
  )
  let index =
    #"{"schemaVersion":2,"manifests":[{"digest":"sha256:"#
    + digest
    + #"","size":"#
    + String(descriptor.count)
    + #"}]}"#
  try Data(index.utf8).write(
    to: export.appending(path: "index.json", directoryHint: .notDirectory)
  )
  try Data(marker.utf8).write(
    to: export.appending(path: "marker.txt", directoryHint: .notDirectory)
  )
}

private func cacheExportURL(root: URL, buildID: UUID) -> URL {
  root
    .appending(path: AppOwnedBuildCacheStore.namespaceDirectoryName, directoryHint: .isDirectory)
    .appending(path: AppOwnedBuildCacheStore.stagingDirectoryName, directoryHint: .isDirectory)
    .appending(path: buildID.uuidString.lowercased(), directoryHint: .isDirectory)
}

private func currentMarker(root: URL) throws -> String {
  let marker = currentCacheURL(root: root)
    .appending(path: "marker.txt", directoryHint: .notDirectory)
  return try String(contentsOf: marker, encoding: .utf8)
}

private func preparedExportURL(
  root: URL,
  buildID: UUID,
  handoffToken: UUID
) -> URL {
  root
    .appending(path: AppOwnedBuildCacheStore.namespaceDirectoryName, directoryHint: .isDirectory)
    .appending(path: AppOwnedBuildCacheStore.preparedDirectoryName, directoryHint: .isDirectory)
    .appending(
      path:
        "\(buildID.uuidString.lowercased())-\(handoffToken.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
}

private func currentCacheURL(root: URL) -> URL {
  root
    .appending(path: AppOwnedBuildCacheStore.namespaceDirectoryName, directoryHint: .isDirectory)
    .appending(path: AppOwnedBuildCacheStore.currentDirectoryName, directoryHint: .isDirectory)
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
