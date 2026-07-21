import XCTest
@testable import NativeContainers

final class LinuxBoxImageAndCreationTests: XCTestCase {
  func testPinnedCatalogTrustIdentityAndBounds() throws {
    let image = try LinuxBoxImageRecord(
      imageID: "debian-13-arm64-v1",
      imageBuildRevision: "linux-box-image-v1",
      guestAgentProtocolVersion: 2,
      sourceURL: URL(string: LinuxBoxImageCatalogPins.sourceURL)!,
      sourceMetadataURL: URL(string: LinuxBoxImageCatalogPins.sourceMetadataURL)!,
      sourceDigestURL: URL(string: LinuxBoxImageCatalogPins.sourceDigestURL)!,
      sourceSHA512: LinuxBoxImageCatalogPins.sourceSHA512,
      rawSHA512: String(repeating: "0", count: 128),
      releaseAssetURL: URL(string: LinuxBoxImageCatalogPins.releaseAssetURL)!,
      compressedSizeBytes: 0,
      logicalSizeBytes: 0,
      compressedSHA256: String(repeating: "0", count: 64),
      published: false
    )
    let catalog = try LinuxBoxImageCatalog(images: [image])
    XCTAssertEqual(catalog.images.first?.sourceSHA512, LinuxBoxImageCatalogPins.sourceSHA512)
    XCTAssertThrowsError(try LinuxBoxImageCatalog.decode(Data(#"{"schemaVersion":1,"images":[],"extra":true}"#.utf8)))
  }

  func testManagedCreationDefaultsAndTemplateMinimum() throws {
    let request = try LinuxBoxManagedCreationRequest(name: "box")
    XCTAssertEqual(request.resources.cpuCount, 4)
    XCTAssertEqual(request.resources.memoryBytes, 8 * VirtualMachineResources.bytesPerGiB)
    XCTAssertEqual(request.resources.diskBytes, 32 * VirtualMachineResources.bytesPerGiB)
    XCTAssertEqual(request.profile, .standard)
    XCTAssertEqual(try LinuxBoxManagedCreationRequest(name: "residential", profile: .residential).profile, .residential)
    XCTAssertThrowsError(
      try LinuxBoxManagedCreationRequest(
        name: "box",
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 7 * VirtualMachineResources.bytesPerGiB
      )
    )
  }

  func testUnpublishedImageCannotEnterCache() async throws {
    let image = try LinuxBoxImageRecord(
      imageID: "debian-13-arm64-v1",
      imageBuildRevision: "linux-box-image-v1",
      guestAgentProtocolVersion: 2,
      sourceURL: URL(string: LinuxBoxImageCatalogPins.sourceURL)!,
      sourceMetadataURL: URL(string: LinuxBoxImageCatalogPins.sourceMetadataURL)!,
      sourceDigestURL: URL(string: LinuxBoxImageCatalogPins.sourceDigestURL)!,
      sourceSHA512: LinuxBoxImageCatalogPins.sourceSHA512,
      rawSHA512: String(repeating: "0", count: 128),
      releaseAssetURL: URL(string: LinuxBoxImageCatalogPins.releaseAssetURL)!,
      compressedSizeBytes: 0,
      logicalSizeBytes: 0,
      compressedSHA256: String(repeating: "0", count: 64),
      published: false
    )
    let cache = LinuxBoxImageCache(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    do {
      _ = try await cache.prepare(image: image)
      XCTFail("an unpublished catalog entry must not be downloaded")
    } catch let error as LinuxBoxImageCacheError {
      XCTAssertEqual(error, .imageNotPublished)
    }
  }

  func testCacheRecoveryRemovesOnlyCanonicalOwnedPartials() async throws {
    let root = temporaryDirectory()
    let image = try makeImage(published: false)
    let catalog = try LinuxBoxImageCatalog(images: [image])
    let imageDirectory = root.appending(path: image.imageID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: imageDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: imageDirectory.path
    )
    let operation = UUID().uuidString.lowercased()
    let ownedPartial = imageDirectory.appending(
      path: ".\(operation).raw.partial"
    )
    XCTAssertTrue(FileManager.default.createFile(
      atPath: ownedPartial.path,
      contents: Data()
    ))
    let unrelated = imageDirectory.appending(path: "operator.partial")
    XCTAssertTrue(FileManager.default.createFile(
      atPath: unrelated.path,
      contents: Data()
    ))

    let cache = LinuxBoxImageCache(rootURL: root)
    try await cache.recover(catalog: catalog)

    XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPartial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testCacheRejectsSymbolicRootDirectory() async throws {
    let parent = temporaryDirectory()
    let target = parent.appending(path: "target", directoryHint: .isDirectory)
    let linked = parent.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
    let catalog = try LinuxBoxImageCatalog(images: [makeImage(published: false)])
    let cache = LinuxBoxImageCache(rootURL: linked)

    do {
      try await cache.recover(catalog: catalog)
      XCTFail("a symbolic cache root must be rejected")
    } catch let error as LinuxBoxImageCacheError {
      XCTAssertEqual(error, .invalidCacheDirectory)
    }
  }

  func testManagedCreationFailureInjectionIsAtomicAtEveryPhase() async throws {
    let image = try makeImage(
      published: true,
      compressedSizeBytes: 1,
      logicalSizeBytes: LinuxBoxImageCatalogPins.minimumTemplateBytes
    )
    let templateRoot = temporaryDirectory()
    let template = templateRoot.appending(path: "template.raw")
    XCTAssertTrue(FileManager.default.createFile(atPath: template.path, contents: nil))
    let templateHandle = try FileHandle(forWritingTo: template)
    try templateHandle.truncate(atOffset: image.logicalSizeBytes)
    try templateHandle.close()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: template.path
    )
    let cache = FixedLinuxBoxImagePreparer(
      cached: LinuxBoxCachedImage(image: image, templateURL: template)
    )

    for phase in LinuxBoxManagedCreationPhase.allCases {
      let root = temporaryDirectory()
      let operationID = UUID()
      let service = LinuxBoxManagedCreationService(
        rootURL: root,
        cache: cache,
        failureInjector: FailingLinuxBoxCreationPhase(phase: phase)
      )
      if phase == .committed {
        let result = try await service.create(
          request: LinuxBoxManagedCreationRequest(name: "committed"),
          image: image,
          operationID: operationID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        XCTAssertEqual(result.manifest.linuxConfiguration?.linuxBoxDescriptor?.profile, .standard)
      } else {
        do {
          _ = try await service.create(
            request: LinuxBoxManagedCreationRequest(name: phase.rawValue),
            image: image,
            operationID: operationID
          )
          XCTFail("phase \(phase.rawValue) should fail before commit")
        } catch LinuxBoxCreationInjectedError.injected {
        }
        let entries = try FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil
        )
        XCTAssertFalse(entries.contains {
          $0.pathExtension == VirtualMachineLibrary.bundleExtension
            || $0.lastPathComponent.hasPrefix(
              VirtualMachineLibrary.managedCreationStagingPrefix
            )
        })
      }
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: template.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o444))
    XCTAssertEqual(
      (attributes[.size] as? NSNumber)?.uint64Value,
      LinuxBoxImageCatalogPins.minimumTemplateBytes
    )
  }

  func testRecoveryRemovesPreManifestManagedCreationPartialOnly() throws {
    let root = temporaryDirectory()
    let store = VirtualMachineBundleStore(rootURL: root, fileManager: .default)
    let operationID = UUID()
    let partial = store.managedCreationStagingDirectory(operationID: operationID)
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: partial.path
    )
    let unrelated = root.appending(path: ".ManagedCreation-not-a-uuid.partial")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)

    try store.removeRecoveryArtifacts()

    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  private func makeImage(
    published: Bool,
    compressedSizeBytes: UInt64 = 0,
    logicalSizeBytes: UInt64 = 0
  ) throws -> LinuxBoxImageRecord {
    try LinuxBoxImageRecord(
      imageID: "debian-13-arm64-v1",
      imageBuildRevision: "linux-box-image-v1",
      guestAgentProtocolVersion: 2,
      sourceURL: URL(string: LinuxBoxImageCatalogPins.sourceURL)!,
      sourceMetadataURL: URL(string: LinuxBoxImageCatalogPins.sourceMetadataURL)!,
      sourceDigestURL: URL(string: LinuxBoxImageCatalogPins.sourceDigestURL)!,
      sourceSHA512: LinuxBoxImageCatalogPins.sourceSHA512,
      rawSHA512: String(repeating: "0", count: 128),
      releaseAssetURL: URL(string: LinuxBoxImageCatalogPins.releaseAssetURL)!,
      compressedSizeBytes: compressedSizeBytes,
      logicalSizeBytes: logicalSizeBytes,
      compressedSHA256: String(repeating: "0", count: 64),
      published: published
    )
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try! FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

}

private struct FixedLinuxBoxImagePreparer: LinuxBoxImagePreparing {
  let cached: LinuxBoxCachedImage

  func prepare(image: LinuxBoxImageRecord) async throws -> LinuxBoxCachedImage {
    cached
  }
}

private enum LinuxBoxCreationInjectedError: Error {
  case injected
}

private struct FailingLinuxBoxCreationPhase: LinuxBoxManagedCreationFailureInjecting {
  let phase: LinuxBoxManagedCreationPhase

  func fail(after phase: LinuxBoxManagedCreationPhase) throws {
    if self.phase == phase {
      throw LinuxBoxCreationInjectedError.injected
    }
  }
}
