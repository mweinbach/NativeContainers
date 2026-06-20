import ContainerAPIClient
import Darwin
import Foundation

protocol ImageBuildArtifactManaging: Sendable {
  func validateArtifact(
    _ artifact: ContainerBuildWorkerResult
  ) async throws -> SecureRegularFileIdentity
  func revalidateArtifact(
    _ artifact: ContainerBuildWorkerResult,
    expectedIdentity: SecureRegularFileIdentity
  ) async throws
  func removeArtifacts(buildID: UUID) async
}

struct AppleImageBuildArtifactManager: ImageBuildArtifactManaging {
  private let store: PrivateBuildArtifactStore
  private let sharedExportRoot: @Sendable () async throws -> URL

  init(
    rootDirectory: URL = PrivateBuildArtifactStore.defaultRootDirectory(),
    sharedExportRoot: @escaping @Sendable () async throws -> URL = {
      let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
      return health.appRoot.appending(path: "builder", directoryHint: .isDirectory)
    }
  ) {
    store = PrivateBuildArtifactStore(rootDirectory: rootDirectory)
    self.sharedExportRoot = sharedExportRoot
  }

  func validateArtifact(
    _ artifact: ContainerBuildWorkerResult
  ) async throws -> SecureRegularFileIdentity {
    let expected = store.artifactURL(buildID: artifact.buildID)
    let actual = URL(filePath: artifact.archivePath).standardizedFileURL
    guard actual == expected else { throw ImageBuildError.workerArtifactMismatch }
    do {
      return try store.validate(
        PrivateBuildArtifact(
          url: actual,
          sha256: artifact.archiveSHA256,
          byteCount: artifact.archiveByteCount
        ),
        buildID: artifact.buildID
      )
    } catch let error as SecureRegularFileValidationError {
      if case .missing = error {
        throw ImageBuildError.missingArtifact(actual.path(percentEncoded: false))
      }
      throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
    } catch {
      throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
    }
  }

  func revalidateArtifact(
    _ artifact: ContainerBuildWorkerResult,
    expectedIdentity: SecureRegularFileIdentity
  ) async throws {
    let actual = URL(filePath: artifact.archivePath).standardizedFileURL
    do {
      try store.revalidate(
        PrivateBuildArtifact(
          url: actual,
          sha256: artifact.archiveSHA256,
          byteCount: artifact.archiveByteCount
        ),
        buildID: artifact.buildID,
        expectedIdentity: expectedIdentity
      )
    } catch let error as SecureRegularFileValidationError {
      if case .missing = error {
        throw ImageBuildError.missingArtifact(actual.path(percentEncoded: false))
      }
      throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
    } catch {
      throw ImageBuildError.unsafeArtifact(actual.path(percentEncoded: false))
    }
  }

  func removeArtifacts(buildID: UUID) async {
    let cleanup = Task.detached(priority: .utility) { [store, sharedExportRoot] in
      try? store.remove(buildID: buildID)
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
