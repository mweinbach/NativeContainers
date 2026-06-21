import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Socktainer install service")
struct SocktainerInstallServiceTests {
  @Test
  func pinnedReleaseUsesReviewedDirectArtifactIdentity() {
    let release = SocktainerRelease.pinned

    #expect(release.version == "1.0.0")
    #expect(release.sourceURL.lastPathComponent == "socktainer")
    #expect(
      release.sha256
        == "8e41e8a75aaf9cb2fa938a7493bbc504d93bfbd14fbf09826d4c57d2150bd020"
    )
    #expect(release.developerTeamIdentifier == "HYSCB8KRL2")
    #expect(release.maximumByteCount == 80 * 1_024 * 1_024)
  }

  @Test
  func installValidatesBeforeAndAfterAtomicPrivateInstall() async throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    let downloader = RecordingArtifactDownloader(sourceURL: fixture.sourceURL)
    let validator = RecordingArtifactValidator()
    let service = SocktainerInstallService(
      installRootURL: fixture.installRootURL,
      downloader: downloader,
      validator: validator
    )

    try await service.install()

    #expect(await downloader.downloadCount == 1)
    #expect(FileManager.default.fileExists(atPath: service.executableURL.path))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: service.executableURL.path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(await service.installationState() == .ready(version: "1.0.0"))
    #expect(validator.validatedURLs.count >= 4)
  }

  @Test
  func unsafeSymlinkedVersionDirectoryFailsBeforeDownload() async throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    let target = fixture.rootURL.appending(path: "redirect", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let versionDirectory = fixture.installRootURL.appending(
      path: SocktainerRelease.pinned.version,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: fixture.installRootURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: versionDirectory,
      withDestinationURL: target
    )
    var metadata = stat()
    #expect(lstat(versionDirectory.nativeContainersPOSIXPath, &metadata) == 0)
    #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    let downloader = RecordingArtifactDownloader(sourceURL: fixture.sourceURL)
    let service = SocktainerInstallService(
      installRootURL: fixture.installRootURL,
      downloader: downloader,
      validator: RecordingArtifactValidator()
    )

    await #expect(throws: DockerCompatibilityError.self) {
      try await service.install()
    }

    #expect(await downloader.downloadCount == 0)
  }

  @Test
  func concreteValidatorRejectsDigestMismatchBeforeSignatureTrust() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    let validator = SocktainerArtifactValidator()

    #expect(throws: DockerCompatibilityError.artifactDigestMismatch) {
      try validator.validate(
        artifactURL: fixture.sourceURL,
        release: .pinned
      )
    }
  }
}

private struct InstallFixture {
  let rootURL: URL
  let installRootURL: URL
  let sourceURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-socktainer-install-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    installRootURL = rootURL.appending(path: "install", directoryHint: .isDirectory)
    sourceURL = rootURL.appending(path: "downloaded-socktainer", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    try Data("not-the-pinned-binary".utf8).write(to: sourceURL)
    #expect(chmod(sourceURL.path(percentEncoded: false), 0o600) == 0)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private actor RecordingArtifactDownloader: SocktainerArtifactDownloading {
  private let sourceURL: URL
  private(set) var downloadCount = 0

  init(sourceURL: URL) {
    self.sourceURL = sourceURL
  }

  func download(
    from sourceURL: URL,
    maximumByteCount: Int64
  ) async throws -> URL {
    downloadCount += 1
    let result = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-downloaded-\(UUID().uuidString.lowercased())",
      directoryHint: .notDirectory
    )
    try FileManager.default.copyItem(at: self.sourceURL, to: result)
    return result
  }
}

private final class RecordingArtifactValidator:
  SocktainerArtifactValidating, @unchecked Sendable
{
  private let lock = NSLock()
  private var urls: [URL] = []

  var validatedURLs: [URL] {
    lock.withLock { urls }
  }

  func validate(
    artifactURL: URL,
    release: SocktainerRelease
  ) throws {
    lock.withLock {
      urls.append(artifactURL)
    }
  }
}
