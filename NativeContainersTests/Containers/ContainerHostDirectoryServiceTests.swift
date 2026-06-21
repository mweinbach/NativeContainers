import ContainerResource
import Foundation
import Testing

@testable import NativeContainers

@Suite("Container host-directory service")
struct ContainerHostDirectoryServiceTests {
  @Test
  func reviewPrepareAndRestartValidationPreserveThePinnedDirectory() throws {
    let fixture = try HostDirectoryFixture()
    defer { fixture.remove() }
    let service = fixture.service
    let operationID = UUID()
    let reviewed = try service.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: fixture.sourceURL,
        containerPath: "/workspace/project",
        isReadOnly: true
      )
    )

    let prepared = try service.prepare([reviewed], operationID: operationID)
    let access = try #require(prepared)
    #expect(access.mounts.count == 1)
    #expect(access.mounts[0].isVirtiofs)
    #expect(access.mounts[0].source == reviewed.lastKnownPath)
    #expect(access.mounts[0].destination == "/workspace/project")
    #expect(access.mounts[0].options == ["ro"])
    access.release()

    let restarted = try service.validateBeforeStart(
      [
        Filesystem.virtiofs(
          source: reviewed.lastKnownPath,
          destination: "/workspace/project",
          options: ["ro"]
        )
      ],
      operationID: operationID
    )
    #expect(restarted.mounts.map(\.destination) == ["/workspace/project"])
    restarted.release()

    service.cleanup(operationID: operationID)
    #expect(throws: ContainerHostDirectoryError.missingManifest) {
      _ = try service.validateBeforeStart([], operationID: operationID)
    }
  }

  @Test
  func rejectsSymbolicDirectoriesAndChangedRuntimeConfiguration() throws {
    let fixture = try HostDirectoryFixture()
    defer { fixture.remove() }
    let link = fixture.rootURL.appending(path: "Link", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: fixture.sourceURL
    )

    #expect(throws: ContainerHostDirectoryError.self) {
      _ = try fixture.service.reviewHostDirectory(
        ContainerHostDirectoryReviewRequest(
          sourceURL: link,
          containerPath: "/workspace/link",
          isReadOnly: true
        )
      )
    }

    let operationID = UUID()
    let reviewed = try fixture.service.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: fixture.sourceURL,
        containerPath: "/workspace/project",
        isReadOnly: false
      )
    )
    let prepared = try fixture.service.prepare([reviewed], operationID: operationID)
    let access = try #require(prepared)
    access.release()
    defer { fixture.service.cleanup(operationID: operationID) }

    #expect(throws: ContainerHostDirectoryError.configurationChanged) {
      _ = try fixture.service.validateBeforeStart(
        [
          Filesystem.virtiofs(
            source: reviewed.lastKnownPath,
            destination: "/workspace/changed",
            options: []
          )
        ],
        operationID: operationID
      )
    }
  }

  @Test
  func manifestStoreRejectsPermissiveRecords() throws {
    let fixture = try HostDirectoryFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let reviewed = try fixture.service.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: fixture.sourceURL,
        containerPath: "/workspace/project",
        isReadOnly: true
      )
    )
    let prepared = try fixture.service.prepare([reviewed], operationID: operationID)
    let access = try #require(prepared)
    access.release()

    let manifestURL = fixture.manifestRootURL.appending(
      path: "\(operationID.uuidString.lowercased()).json",
      directoryHint: .notDirectory
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.nativeContainersPOSIXPath
    )

    #expect(throws: ContainerHostDirectoryError.invalidManifest) {
      _ = try fixture.manifestStore.load(operationID: operationID)
    }
  }
}

private struct HostDirectoryFixture {
  let rootURL: URL
  let sourceURL: URL
  let manifestRootURL: URL
  let manifestStore: FileContainerHostDirectoryManifestStore
  let service: AppleContainerHostDirectoryService

  init() throws {
    rootURL = URL(
      filePath: "/private/tmp/nca-host-dir-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    sourceURL = rootURL.appending(path: "Source", directoryHint: .isDirectory)
    manifestRootURL = rootURL.appending(path: "Manifests", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceURL,
      withIntermediateDirectories: true
    )
    manifestStore = FileContainerHostDirectoryManifestStore(rootURL: manifestRootURL)
    service = AppleContainerHostDirectoryService(manifestStore: manifestStore)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
