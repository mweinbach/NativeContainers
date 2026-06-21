import CryptoKit
import Darwin
import Foundation

protocol DockerComposeClientInstalling: Sendable {
  var release: DockerComposeRelease { get }
  var executableURL: URL { get }
  var provenanceURL: URL { get }

  func snapshot() async -> DockerComposeClientSnapshot
  func installationState() async -> DockerComposeClientInstallationState
  func install() async throws
}

protocol DockerComposeArtifactDownloading: Sendable {
  func download(
    from sourceURL: URL,
    artifactName: String,
    maximumByteCount: Int64
  ) async throws -> URL
}

protocol DockerComposeArtifactValidating: Sendable {
  func validateBinary(
    at binaryURL: URL,
    release: DockerComposeRelease
  ) throws

  func validateProvenance(
    at provenanceURL: URL,
    release: DockerComposeRelease
  ) throws
}

actor DockerComposeClientInstallService: DockerComposeClientInstalling {
  nonisolated let release: DockerComposeRelease
  nonisolated let executableURL: URL
  nonisolated let provenanceURL: URL

  private let installRootURL: URL
  private let installDirectoryURL: URL
  private let downloader: any DockerComposeArtifactDownloading
  private let validator: any DockerComposeArtifactValidating
  private let fileManager: FileManager

  init(
    release: DockerComposeRelease = .pinned,
    installRootURL: URL? = nil,
    downloader: any DockerComposeArtifactDownloading =
      URLSessionDockerComposeArtifactDownloader(),
    validator: any DockerComposeArtifactValidating = DockerComposeArtifactValidator(),
    fileManager: FileManager = .default
  ) {
    self.release = release
    let root =
      installRootURL
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Compatibility", directoryHint: .isDirectory)
      .appending(path: "DockerCompose", directoryHint: .isDirectory)
    self.installRootURL = root
    installDirectoryURL = root.appending(path: release.version, directoryHint: .isDirectory)
    executableURL = installDirectoryURL.appending(
      path: "docker-compose",
      directoryHint: .notDirectory
    )
    provenanceURL = installDirectoryURL.appending(
      path: "provenance.json",
      directoryHint: .notDirectory
    )
    self.downloader = downloader
    self.validator = validator
    self.fileManager = fileManager
  }

  func snapshot() async -> DockerComposeClientSnapshot {
    DockerComposeClientSnapshot(
      release: release,
      installation: await installationState(),
      executableURL: executableURL,
      provenanceURL: provenanceURL
    )
  }

  func installationState() async -> DockerComposeClientInstallationState {
    let binaryExists = entryExists(at: executableURL)
    let provenanceExists = entryExists(at: provenanceURL)
    guard binaryExists || provenanceExists else {
      return .notInstalled
    }
    guard binaryExists, provenanceExists else {
      return .invalid(reason: DockerComposeClientError.incompleteInstallation.localizedDescription)
    }

    do {
      try validateInstallDirectories()
      try validator.validateProvenance(at: provenanceURL, release: release)
      try validator.validateBinary(at: executableURL, release: release)
      return .ready(version: release.version)
    } catch {
      return .invalid(reason: error.localizedDescription)
    }
  }

  func install() async throws {
    try ensurePrivateInstallDirectories()

    async let downloadedBinary = downloader.download(
      from: release.binaryURL,
      artifactName: "binary",
      maximumByteCount: release.maximumBinaryByteCount
    )
    async let downloadedProvenance = downloader.download(
      from: release.provenanceURL,
      artifactName: "provenance",
      maximumByteCount: release.maximumProvenanceByteCount
    )
    let (binaryDownloadURL, provenanceDownloadURL) =
      try await (downloadedBinary, downloadedProvenance)
    defer {
      try? fileManager.removeItem(at: binaryDownloadURL)
      try? fileManager.removeItem(at: provenanceDownloadURL)
    }

    try validator.validateProvenance(at: provenanceDownloadURL, release: release)
    try validator.validateBinary(at: binaryDownloadURL, release: release)

    let stagingProvenanceURL = stagingURL(prefix: "provenance")
    let stagingBinaryURL = stagingURL(prefix: "docker-compose")
    defer {
      try? fileManager.removeItem(at: stagingProvenanceURL)
      try? fileManager.removeItem(at: stagingBinaryURL)
    }

    try stage(
      sourceURL: provenanceDownloadURL,
      destinationURL: stagingProvenanceURL,
      permissions: 0o600
    )
    try stage(
      sourceURL: binaryDownloadURL,
      destinationURL: stagingBinaryURL,
      permissions: 0o700
    )
    try validator.validateProvenance(at: stagingProvenanceURL, release: release)
    try validator.validateBinary(at: stagingBinaryURL, release: release)

    try publish(stagingProvenanceURL, to: provenanceURL)
    try publish(stagingBinaryURL, to: executableURL)

    try validateInstallDirectories()
    try validator.validateProvenance(at: provenanceURL, release: release)
    try validator.validateBinary(at: executableURL, release: release)
  }

  private func ensurePrivateInstallDirectories() throws {
    try ensureDirectory(at: installRootURL)
    try ensureDirectory(at: installDirectoryURL)
    try validateInstallDirectories()
  }

  private func ensureDirectory(at url: URL) throws {
    let path = url.nativeContainersPOSIXPath
    var metadata = stat()
    if lstat(path, &metadata) == 0 {
      try validateDirectory(at: url)
      return
    }
    guard errno == ENOENT else {
      throw DockerComposeClientError.unsafeInstallLocation(path)
    }

    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    guard chmod(path, 0o700) == 0 else {
      throw DockerComposeClientError.unsafeInstallLocation(path)
    }
    try validateDirectory(at: url)
  }

  private func validateInstallDirectories() throws {
    try validateDirectory(at: installRootURL)
    try validateDirectory(at: installDirectoryURL)
  }

  private func validateDirectory(at url: URL) throws {
    let path = url.nativeContainersPOSIXPath
    var metadata = stat()
    guard
      lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw DockerComposeClientError.unsafeInstallLocation(path)
    }
  }

  private func stage(
    sourceURL: URL,
    destinationURL: URL,
    permissions: mode_t
  ) throws {
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    guard chmod(destinationURL.nativeContainersPOSIXPath, permissions) == 0 else {
      throw DockerComposeClientError.unsafeInstallLocation(
        destinationURL.nativeContainersPOSIXPath
      )
    }
  }

  private func publish(_ stagingURL: URL, to destinationURL: URL) throws {
    let result = stagingURL.nativeContainersPOSIXPath.withCString { source in
      destinationURL.nativeContainersPOSIXPath.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw DockerComposeClientError.unsafeInstallLocation(
        destinationURL.nativeContainersPOSIXPath
      )
    }
  }

  private func stagingURL(prefix: String) -> URL {
    installDirectoryURL.appending(
      path: ".\(prefix)-\(UUID().uuidString.lowercased()).tmp",
      directoryHint: .notDirectory
    )
  }

  private func entryExists(at url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.nativeContainersPOSIXPath, &metadata) == 0
  }
}

struct URLSessionDockerComposeArtifactDownloader: DockerComposeArtifactDownloading {
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
  }

  func download(
    from sourceURL: URL,
    artifactName: String,
    maximumByteCount: Int64
  ) async throws -> URL {
    guard sourceURL.scheme?.lowercased() == "https" else {
      throw DockerComposeClientError.downloadResponse(artifact: artifactName, status: 0)
    }

    var request = URLRequest(
      url: sourceURL,
      cachePolicy: .reloadIgnoringLocalCacheData
    )
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (temporaryURL, response) = try await session.download(for: request)
    guard
      let response = response as? HTTPURLResponse,
      response.url?.scheme?.lowercased() == "https"
    else {
      throw DockerComposeClientError.downloadResponse(artifact: artifactName, status: 0)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw DockerComposeClientError.downloadResponse(
        artifact: artifactName,
        status: response.statusCode
      )
    }
    if response.expectedContentLength > maximumByteCount {
      throw DockerComposeClientError.artifactTooLarge(
        artifact: artifactName,
        byteCount: response.expectedContentLength
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0, byteCount <= maximumByteCount else {
      throw DockerComposeClientError.artifactTooLarge(
        artifact: artifactName,
        byteCount: byteCount
      )
    }

    let retainedURL = FileManager.default.temporaryDirectory.appending(
      path:
        "nativecontainers-docker-compose-\(artifactName)-\(UUID().uuidString.lowercased()).download",
      directoryHint: .notDirectory
    )
    do {
      try FileManager.default.copyItem(at: temporaryURL, to: retainedURL)
      guard chmod(retainedURL.nativeContainersPOSIXPath, 0o600) == 0 else {
        throw DockerComposeClientError.unsafeInstallLocation(
          retainedURL.nativeContainersPOSIXPath
        )
      }
      return retainedURL
    } catch {
      try? FileManager.default.removeItem(at: retainedURL)
      throw error
    }
  }
}

struct DockerComposeArtifactValidator: DockerComposeArtifactValidating {
  private struct ProvenanceStatement: Decodable {
    let type: String
    let predicateType: String
    let subject: [Subject]
    let predicate: Predicate

    enum CodingKeys: String, CodingKey {
      case type = "_type"
      case predicateType
      case subject
      case predicate
    }
  }

  private struct Subject: Decodable {
    let name: String
    let digest: [String: String]
  }

  private struct Predicate: Decodable {
    let buildDefinition: BuildDefinition
    let runDetails: RunDetails
  }

  private struct BuildDefinition: Decodable {
    let buildType: String
    let externalParameters: ExternalParameters
  }

  private struct ExternalParameters: Decodable {
    let configSource: ConfigSource
  }

  private struct ConfigSource: Decodable {
    let uri: String
    let digest: [String: String]
    let path: String
  }

  private struct RunDetails: Decodable {
    let builder: Builder
  }

  private struct Builder: Decodable {
    let id: String
  }

  func validateBinary(
    at binaryURL: URL,
    release: DockerComposeRelease
  ) throws {
    try validateRegularFile(
      at: binaryURL,
      maximumByteCount: release.maximumBinaryByteCount
    )
    guard try sha256(of: binaryURL) == release.binarySHA256 else {
      throw DockerComposeClientError.binaryDigestMismatch
    }

    let handle = try FileHandle(forReadingFrom: binaryURL)
    defer { try? handle.close() }
    let header = try handle.read(upToCount: 8) ?? Data()
    guard Array(header) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] else {
      throw DockerComposeClientError.binaryArchitectureInvalid
    }
  }

  func validateProvenance(
    at provenanceURL: URL,
    release: DockerComposeRelease
  ) throws {
    try validateRegularFile(
      at: provenanceURL,
      maximumByteCount: release.maximumProvenanceByteCount
    )
    guard try sha256(of: provenanceURL) == release.provenanceSHA256 else {
      throw DockerComposeClientError.provenanceDigestMismatch
    }

    let data = try Data(contentsOf: provenanceURL, options: .mappedIfSafe)
    let statement: ProvenanceStatement
    do {
      statement = try JSONDecoder().decode(ProvenanceStatement.self, from: data)
    } catch {
      throw DockerComposeClientError.provenanceInvalid("the statement is not valid JSON")
    }

    guard statement.type == "https://in-toto.io/Statement/v0.1" else {
      throw DockerComposeClientError.provenanceInvalid("unexpected in-toto statement type")
    }
    guard statement.predicateType == "https://slsa.dev/provenance/v1" else {
      throw DockerComposeClientError.provenanceInvalid("unexpected SLSA predicate type")
    }
    guard
      statement.subject.count == 1,
      statement.subject[0].name == release.provenanceSubjectName,
      statement.subject[0].digest["sha256"] == release.binarySHA256
    else {
      throw DockerComposeClientError.provenanceInvalid(
        "the subject does not identify the pinned binary"
      )
    }
    guard
      statement.predicate.buildDefinition.buildType == release.buildType,
      statement.predicate.buildDefinition.externalParameters.configSource.uri
        == release.sourceURI,
      statement.predicate.buildDefinition.externalParameters.configSource.digest["sha1"]
        == release.sourceRevision,
      statement.predicate.buildDefinition.externalParameters.configSource.path == "Dockerfile",
      statement.predicate.runDetails.builder.id == release.builderID
    else {
      throw DockerComposeClientError.provenanceInvalid(
        "the source or builder identity does not match the pinned release"
      )
    }
  }

  private func validateRegularFile(
    at url: URL,
    maximumByteCount: Int64
  ) throws {
    let path = url.standardizedFileURL.nativeContainersPOSIXPath
    var metadata = stat()
    guard
      lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_size <= maximumByteCount,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw DockerComposeClientError.unsafeInstallLocation(path)
    }
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

actor UnavailableDockerComposeClientService: DockerComposeClientInstalling {
  nonisolated let release = DockerComposeRelease.pinned
  nonisolated let executableURL = URL(filePath: "/unavailable/docker-compose")
  nonisolated let provenanceURL = URL(filePath: "/unavailable/provenance.json")

  private let reason: String

  init(reason: String = "not configured") {
    self.reason = reason
  }

  func snapshot() async -> DockerComposeClientSnapshot {
    DockerComposeClientSnapshot(
      release: release,
      installation: .invalid(reason: reason),
      executableURL: executableURL,
      provenanceURL: provenanceURL
    )
  }

  func installationState() async -> DockerComposeClientInstallationState {
    .invalid(reason: reason)
  }

  func install() async throws {
    throw DockerComposeClientError.unavailable(reason)
  }
}
