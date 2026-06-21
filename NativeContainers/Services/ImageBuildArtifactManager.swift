import ContainerAPIClient
import Darwin
import Foundation

enum ImageBuildArtifactIdentity: Equatable, Sendable {
  case regularFile(SecureRegularFileIdentity)
  case directory(PrivateBuildDirectoryIdentity)
}

protocol ImageBuildArtifactManaging: Sendable {
  func validateArtifact(
    _ result: ContainerBuildWorkerResult
  ) async throws -> ImageBuildArtifactIdentity
  func revalidateArtifact(
    _ result: ContainerBuildWorkerResult,
    expectedIdentity: ImageBuildArtifactIdentity
  ) async throws
  func removeArtifacts(buildID: UUID) async
}

struct AppleImageBuildArtifactManager: ImageBuildArtifactManaging {
  private let fileStore: PrivateBuildArtifactStore
  private let directoryStore: PrivateBuildDirectoryStore
  private let sharedExportRoot: @Sendable () async throws -> URL

  init(
    rootDirectory: URL = PrivateBuildArtifactStore.defaultRootDirectory(),
    sharedExportRoot: @escaping @Sendable () async throws -> URL = {
      let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
      return health.appRoot.appending(path: "builder", directoryHint: .isDirectory)
    }
  ) {
    fileStore = PrivateBuildArtifactStore(rootDirectory: rootDirectory)
    directoryStore = PrivateBuildDirectoryStore(rootDirectory: rootDirectory)
    self.sharedExportRoot = sharedExportRoot
  }

  func validateArtifact(
    _ result: ContainerBuildWorkerResult
  ) async throws -> ImageBuildArtifactIdentity {
    let artifact = result.artifact
    switch artifact.kind {
    case .ociArchive, .rootFilesystemArchive:
      let expected = fileStore.artifactURL(buildID: result.buildID)
      let actual = URL(filePath: artifact.path).standardizedFileURL
      guard actual == expected, artifact.entryCount == nil else {
        throw ImageBuildError.workerArtifactMismatch
      }
      do {
        let identity = try fileStore.validate(
          PrivateBuildArtifact(
            url: actual,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount
          ),
          buildID: result.buildID
        )
        return .regularFile(identity)
      } catch let error as SecureRegularFileValidationError {
        if case .missing = error {
          throw ImageBuildError.missingArtifact(actual.path(percentEncoded: false))
        }
        throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
      } catch let error as PrivateBuildArtifactStoreError {
        if case .ioFailure(_, _, let code) = error, code == ENOENT {
          throw ImageBuildError.missingArtifact(actual.path(percentEncoded: false))
        }
        throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
      } catch {
        throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
      }

    case .rootFilesystemDirectory:
      let expected = directoryStore.artifactURL(buildID: result.buildID)
      let actual = URL(filePath: artifact.path).standardizedFileURL
      guard
        actual == expected,
        let entryCount = artifact.entryCount,
        entryCount >= 0
      else {
        throw ImageBuildError.workerArtifactMismatch
      }
      do {
        let identity = try directoryStore.validate(
          PrivateBuildDirectoryArtifact(
            url: actual,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            entryCount: entryCount
          ),
          buildID: result.buildID
        )
        return .directory(identity)
      } catch let error as PrivateBuildDirectoryStoreError {
        if case .ioFailure(_, _, let code) = error, code == ENOENT {
          throw ImageBuildError.missingArtifact(actual.path(percentEncoded: false))
        }
        throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
      } catch {
        throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
      }
    }
  }

  func revalidateArtifact(
    _ result: ContainerBuildWorkerResult,
    expectedIdentity: ImageBuildArtifactIdentity
  ) async throws {
    let artifact = result.artifact
    do {
      switch (artifact.kind, expectedIdentity) {
      case (.ociArchive, .regularFile(let identity)),
        (.rootFilesystemArchive, .regularFile(let identity)):
        try fileStore.revalidate(
          PrivateBuildArtifact(
            url: URL(filePath: artifact.path).standardizedFileURL,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount
          ),
          buildID: result.buildID,
          expectedIdentity: identity
        )

      case (.rootFilesystemDirectory, .directory(let identity)):
        guard let entryCount = artifact.entryCount else {
          throw ImageBuildError.workerArtifactMismatch
        }
        try directoryStore.revalidate(
          PrivateBuildDirectoryArtifact(
            url: URL(filePath: artifact.path).standardizedFileURL,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            entryCount: entryCount
          ),
          buildID: result.buildID,
          expectedIdentity: identity
        )

      default:
        throw ImageBuildError.workerArtifactMismatch
      }
    } catch let error as ImageBuildError {
      throw error
    } catch {
      throw ImageBuildError.unsafeArtifact(artifact.path)
    }
  }

  func removeArtifacts(buildID: UUID) async {
    let cleanup = Task.detached(priority: .utility) { [fileStore, sharedExportRoot] in
      try? fileStore.remove(buildID: buildID)
      guard let root = try? await sharedExportRoot() else { return }
      let directory = root.standardizedFileURL.appending(
        path: buildID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      var metadata = stat()
      guard
        Darwin.lstat(directory.path(percentEncoded: false), &metadata) == 0,
        metadata.st_uid == geteuid()
      else { return }
      try? FileManager.default.removeItem(at: directory)
    }
    await cleanup.value
  }
}
