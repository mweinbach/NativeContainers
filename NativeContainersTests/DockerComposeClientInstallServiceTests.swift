import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Docker Compose client installer")
struct DockerComposeClientInstallServiceTests {
  @Test
  func pinnedReleaseUsesReviewedOfficialArtifactAndProvenance() {
    let release = DockerComposeRelease.pinned

    #expect(release.version == "5.1.4")
    #expect(release.binaryURL.lastPathComponent == "docker-compose-darwin-aarch64")
    #expect(
      release.binarySHA256
        == "4cad7fc67dd089a598a15598ad38d04e6f23bf299846d26b2c572f1f96a7c49f"
    )
    #expect(
      release.provenanceURL.lastPathComponent
        == "docker-compose-darwin-aarch64.provenance.json"
    )
    #expect(
      release.provenanceSHA256
        == "983374926035c526e8dedb590b18c3cb43f47b31c39a75df8c98d61ceb662d18"
    )
    #expect(release.sourceURI.hasSuffix("docker/compose.git#refs/tags/v5.1.4"))
    #expect(release.sourceRevision == "6ce6411902e8e3c9be91be0c572b2441486357f7")
    #expect(release.maximumBinaryByteCount == 40 * 1_024 * 1_024)
    #expect(release.maximumProvenanceByteCount == 1 * 1_024 * 1_024)
  }

  @Test
  func validatorAcceptsPinnedShapeForThinArm64Binary() throws {
    let fixture = try ComposeArtifactFixture()
    defer { fixture.remove() }

    let validator = DockerComposeArtifactValidator()
    try validator.validateBinary(at: fixture.binaryURL, release: fixture.release)
    try validator.validateProvenance(
      at: fixture.provenanceURL,
      release: fixture.release
    )
  }

  @Test
  func validatorRejectsNonArm64MachOEvenWhenDigestMatches() throws {
    let fixture = try ComposeArtifactFixture(
      binaryData: Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01, 0x01])
    )
    defer { fixture.remove() }

    #expect(throws: DockerComposeClientError.binaryArchitectureInvalid) {
      try DockerComposeArtifactValidator().validateBinary(
        at: fixture.binaryURL,
        release: fixture.release
      )
    }
  }

  @Test
  func validatorRejectsProvenanceForAnotherSubject() throws {
    let fixture = try ComposeArtifactFixture(
      provenanceSubjectDigest: String(repeating: "0", count: 64)
    )
    defer { fixture.remove() }

    #expect(throws: DockerComposeClientError.self) {
      try DockerComposeArtifactValidator().validateProvenance(
        at: fixture.provenanceURL,
        release: fixture.release
      )
    }
  }

  @Test
  func installPublishesVerifiedPrivateBinaryAndProvenance() async throws {
    let fixture = try ComposeArtifactFixture()
    defer { fixture.remove() }
    let downloader = CopyingComposeArtifactDownloader(
      binarySourceURL: fixture.binaryURL,
      provenanceSourceURL: fixture.provenanceURL
    )
    let service = DockerComposeClientInstallService(
      release: fixture.release,
      installRootURL: fixture.installRootURL,
      downloader: downloader
    )

    try await service.install()

    #expect(await downloader.downloadCount == 2)
    #expect(
      service.executableURL
        == fixture.installRootURL
        .appending(path: fixture.release.version, directoryHint: .isDirectory)
        .appending(path: "docker-compose", directoryHint: .notDirectory)
    )
    #expect(try Data(contentsOf: service.executableURL) == fixture.binaryData)
    #expect(try Data(contentsOf: service.provenanceURL) == fixture.provenanceData)
    #expect(try permissions(at: service.executableURL) == 0o700)
    #expect(try permissions(at: service.provenanceURL) == 0o600)
    #expect(
      await service.installationState() == .ready(version: fixture.release.version)
    )
  }

  @Test
  func incompletePrivateInstallFailsClosed() async throws {
    let fixture = try ComposeArtifactFixture()
    defer { fixture.remove() }
    let versionDirectory = fixture.installRootURL.appending(
      path: fixture.release.version,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: versionDirectory,
      withIntermediateDirectories: true
    )
    try fixture.binaryData.write(
      to: versionDirectory.appending(path: "docker-compose")
    )

    let service = DockerComposeClientInstallService(
      release: fixture.release,
      installRootURL: fixture.installRootURL
    )

    guard case .invalid(let reason) = await service.installationState() else {
      Issue.record("Expected an incomplete installation to be invalid")
      return
    }
    #expect(reason.contains("incomplete"))
  }

  @Test
  func symlinkedInstallRootFailsBeforeAnyDownload() async throws {
    let fixture = try ComposeArtifactFixture()
    defer { fixture.remove() }
    let targetURL = fixture.rootURL.appending(path: "redirect", directoryHint: .isDirectory)
    let symlinkURL = fixture.rootURL.appending(path: "unsafe", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: symlinkURL.path,
      withDestinationPath: targetURL.path
    )
    let downloader = CopyingComposeArtifactDownloader(
      binarySourceURL: fixture.binaryURL,
      provenanceSourceURL: fixture.provenanceURL
    )
    let service = DockerComposeClientInstallService(
      release: fixture.release,
      installRootURL: symlinkURL,
      downloader: downloader
    )

    await #expect(throws: DockerComposeClientError.self) {
      try await service.install()
    }
    #expect(await downloader.downloadCount == 0)
  }
}

private struct ComposeArtifactFixture {
  let rootURL: URL
  let installRootURL: URL
  let binaryURL: URL
  let provenanceURL: URL
  let binaryData: Data
  let provenanceData: Data
  let release: DockerComposeRelease

  init(
    binaryData: Data = Data([
      0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x01,
    ]),
    provenanceSubjectDigest: String? = nil
  ) throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-compose-install-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    self.rootURL = rootURL
    installRootURL = rootURL.appending(path: "install", directoryHint: .isDirectory)
    self.binaryData = binaryData

    let binarySHA256 = Self.sha256(binaryData)
    let provenanceObject: [String: Any] = [
      "_type": "https://in-toto.io/Statement/v0.1",
      "predicateType": "https://slsa.dev/provenance/v1",
      "subject": [
        [
          "name": "docker-compose-darwin-aarch64",
          "digest": ["sha256": provenanceSubjectDigest ?? binarySHA256],
        ]
      ],
      "predicate": [
        "buildDefinition": [
          "buildType":
            "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
          "externalParameters": [
            "configSource": [
              "uri": "https://github.com/docker/compose.git#refs/tags/v5.1.4",
              "digest": ["sha1": "fixture-source-revision"],
              "path": "Dockerfile",
            ]
          ],
        ],
        "runDetails": [
          "builder": ["id": "https://github.com/docker/compose/actions/runs/fixture"]
        ],
      ],
    ]
    provenanceData = try JSONSerialization.data(
      withJSONObject: provenanceObject,
      options: [.sortedKeys]
    )
    release = DockerComposeRelease(
      version: "5.1.4-test",
      binaryURL: URL(string: "https://example.com/docker-compose")!,
      binarySHA256: binarySHA256,
      provenanceURL: URL(string: "https://example.com/provenance.json")!,
      provenanceSHA256: Self.sha256(provenanceData),
      provenanceSubjectName: "docker-compose-darwin-aarch64",
      sourceURI: "https://github.com/docker/compose.git#refs/tags/v5.1.4",
      sourceRevision: "fixture-source-revision",
      buildType:
        "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
      builderID: "https://github.com/docker/compose/actions/runs/fixture",
      maximumBinaryByteCount: 1_024,
      maximumProvenanceByteCount: 16 * 1_024
    )

    binaryURL = rootURL.appending(path: "source-binary", directoryHint: .notDirectory)
    provenanceURL = rootURL.appending(
      path: "source-provenance.json",
      directoryHint: .notDirectory
    )
    try binaryData.write(to: binaryURL)
    try provenanceData.write(to: provenanceURL)
    guard
      chmod(binaryURL.nativeContainersPOSIXPath, 0o600) == 0,
      chmod(provenanceURL.nativeContainersPOSIXPath, 0o600) == 0
    else {
      throw DockerComposeClientError.unsafeInstallLocation(rootURL.path)
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private actor CopyingComposeArtifactDownloader: DockerComposeArtifactDownloading {
  private let binarySourceURL: URL
  private let provenanceSourceURL: URL
  private(set) var downloadCount = 0

  init(
    binarySourceURL: URL,
    provenanceSourceURL: URL
  ) {
    self.binarySourceURL = binarySourceURL
    self.provenanceSourceURL = provenanceSourceURL
  }

  func download(
    from sourceURL: URL,
    artifactName: String,
    maximumByteCount: Int64
  ) async throws -> URL {
    downloadCount += 1
    let source = artifactName == "binary" ? binarySourceURL : provenanceSourceURL
    let destination = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-compose-downloader-\(UUID().uuidString.lowercased())"
    )
    try FileManager.default.copyItem(at: source, to: destination)
    guard chmod(destination.nativeContainersPOSIXPath, 0o600) == 0 else {
      throw DockerComposeClientError.unsafeInstallLocation(destination.path)
    }
    return destination
  }
}

private func permissions(at url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}
