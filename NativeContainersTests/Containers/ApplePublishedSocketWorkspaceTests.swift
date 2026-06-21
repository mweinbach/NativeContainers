import ContainerResource
import Darwin
import Foundation
import SystemPackage
import Testing

@testable import NativeContainers

@Suite("Published socket workspace")
struct ApplePublishedSocketWorkspaceTests {
  @Test
  func generatesOperationScopedSocketsInsidePrivateDirectory() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "api.sock",
      containerPath: "/run/api.sock"
    )

    let sockets = try fixture.workspace.prepare([publication], operationID: operationID)
    let socket = try #require(sockets.first)
    let operationDirectory = fixture.operationDirectory(operationID)

    #expect(socket.containerPath.string == "/run/api.sock")
    #expect(
      socket.hostPath.string
        == operationDirectory.appending(path: "api.sock").path(percentEncoded: false))
    #expect(try permissions(of: fixture.rootURL) & 0o077 == 0)
    #expect(try permissions(of: operationDirectory) & 0o077 == 0)
    try fixture.workspace.validateBeforeStart(sockets, operationID: operationID)
  }

  @Test
  func occupiedLeafIsRejectedWithoutDeletingIt() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "api.sock",
      containerPath: "/run/api.sock"
    )
    _ = try fixture.workspace.prepare([publication], operationID: operationID)
    let occupiedURL = fixture.operationDirectory(operationID).appending(path: "api.sock")
    try Data("keep".utf8).write(to: occupiedURL)

    #expect(
      throws: PublishedSocketWorkspaceError.hostPathOccupied(
        occupiedURL.path(percentEncoded: false))
    ) {
      try fixture.workspace.prepare([publication], operationID: operationID)
    }
    #expect(try String(contentsOf: occupiedURL, encoding: .utf8) == "keep")
  }

  @Test
  func startValidationRejectsPathsOutsideOwnedOperationDirectory() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "api.sock",
      containerPath: "/run/api.sock"
    )
    _ = try fixture.workspace.prepare([publication], operationID: operationID)
    let outside = try PublishSocket(
      containerPath: FilePath("/run/api.sock"),
      hostPath: FilePath("/tmp/outside.sock")
    )

    #expect(throws: PublishedSocketWorkspaceError.outsideOwnedWorkspace) {
      try fixture.workspace.validateBeforeStart([outside], operationID: operationID)
    }
  }

  @Test
  func rejectsHostPathsBeyondPortableUnixSocketLimit() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "\(String(repeating: "a", count: 80)).sock",
      containerPath: "/run/api.sock"
    )

    #expect(throws: PublishedSocketWorkspaceError.hostPathTooLong) {
      try fixture.workspace.prepare([publication], operationID: operationID)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.operationDirectory(operationID).path(percentEncoded: false)
      )
    )
  }

  @Test
  func startValidationRecreatesADeletedPrivateOperationDirectory() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let operationID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "api.sock",
      containerPath: "/run/api.sock"
    )
    let sockets = try fixture.workspace.prepare([publication], operationID: operationID)
    let operationDirectory = fixture.operationDirectory(operationID)
    try FileManager.default.removeItem(at: operationDirectory)

    try fixture.workspace.validateBeforeStart(sockets, operationID: operationID)

    #expect(
      FileManager.default.fileExists(
        atPath: operationDirectory.path(percentEncoded: false)
      )
    )
  }

  @Test
  func cleanupRemovesOnlyTheReviewedOperationDirectory() throws {
    let fixture = SocketWorkspaceFixture()
    defer { fixture.remove() }
    let firstID = UUID()
    let secondID = UUID()
    let publication = try ContainerUnixSocketPublication(
      hostSocketName: "api.sock",
      containerPath: "/run/api.sock"
    )
    _ = try fixture.workspace.prepare([publication], operationID: firstID)
    _ = try fixture.workspace.prepare([publication], operationID: secondID)

    fixture.workspace.cleanup(operationID: firstID)

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.operationDirectory(firstID).path(percentEncoded: false)))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.operationDirectory(secondID).path(percentEncoded: false)))
  }

  private func permissions(of url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return info.st_mode
  }
}

private struct SocketWorkspaceFixture {
  let rootURL: URL
  let workspace: ApplePublishedSocketWorkspace

  init() {
    rootURL = URL(
      filePath: "/private/tmp",
      directoryHint: .isDirectory
    ).appending(
      path: "Native Containers Sockets -\(UUID().uuidString.prefix(8))",
      directoryHint: .isDirectory
    )
    workspace = ApplePublishedSocketWorkspace(rootURL: rootURL)
  }

  func operationDirectory(_ operationID: UUID) -> URL {
    rootURL.appending(
      path: operationID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
