import Darwin
import Foundation

protocol SocktainerComposeFixtureWorkspaceManaging: Sendable {
  func prepareFixture(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) throws -> URL
  func removeFixture(at fileURL: URL)
}

struct FileSocktainerComposeFixtureWorkspace:
  SocktainerComposeFixtureWorkspaceManaging
{
  func prepareFixture(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) throws -> URL {
    let workspacePath = configuration.workspaceURL.nativeContainersPOSIXPath
    var metadata = stat()
    guard
      lstat(workspacePath, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw SocktainerComposeLiveFixtureError.unsafeWorkspace(workspacePath)
    }

    let composeFileURL = configuration.workspaceURL.appending(
      path: "compose-live-fixture.yaml",
      directoryHint: .notDirectory
    )
    guard !FileManager.default.fileExists(atPath: composeFileURL.nativeContainersPOSIXPath) else {
      throw SocktainerComposeLiveFixtureError.unsafeWorkspace(
        "The fixture file already exists."
      )
    }

    do {
      try composeYAML(configuration: configuration).write(
        to: composeFileURL,
        atomically: true,
        encoding: .utf8
      )
      guard chmod(composeFileURL.nativeContainersPOSIXPath, 0o600) == 0 else {
        throw SocktainerComposeLiveFixtureError.unsafeWorkspace(
          "The fixture file permissions could not be restricted."
        )
      }
      return composeFileURL
    } catch let error as SocktainerComposeLiveFixtureError {
      try? FileManager.default.removeItem(at: composeFileURL)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: composeFileURL)
      throw SocktainerComposeLiveFixtureError.unsafeWorkspace(
        error.localizedDescription
      )
    }
  }

  func removeFixture(at fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL)
  }

  private func composeYAML(
    configuration: SocktainerComposeLiveFixtureConfiguration
  ) -> String {
    """
    services:
      probe:
        image: docker.io/library/alpine:3.20
        container_name: \(configuration.containerName)
        command: ["sh", "-c", "trap 'exit 0' TERM INT; while true; do sleep 1; done"]
        volumes:
          - data:/fixture
        networks:
          - default
    volumes:
      data:
        name: \(configuration.volumeName)
    networks:
      default:
        name: \(configuration.networkName)
    """
  }
}
