import CryptoKit
import Darwin
import Foundation
import Security

protocol SocktainerInstalling: Sendable {
  var release: SocktainerRelease { get }
  var executableURL: URL { get }
  func installationState() async -> SocktainerInstallationState
  func install() async throws
}

protocol SocktainerArtifactDownloading: Sendable {
  func download(
    from sourceURL: URL,
    maximumByteCount: Int64
  ) async throws -> URL
}

protocol SocktainerArtifactValidating: Sendable {
  func validate(
    artifactURL: URL,
    release: SocktainerRelease
  ) throws
}

actor SocktainerInstallService: SocktainerInstalling {
  nonisolated let release: SocktainerRelease
  nonisolated let executableURL: URL

  private let installDirectoryURL: URL
  private let downloader: any SocktainerArtifactDownloading
  private let validator: any SocktainerArtifactValidating
  private let fileManager: FileManager

  init(
    release: SocktainerRelease = .pinned,
    installRootURL: URL? = nil,
    downloader: any SocktainerArtifactDownloading = URLSessionSocktainerArtifactDownloader(),
    validator: any SocktainerArtifactValidating = SocktainerArtifactValidator(),
    fileManager: FileManager = .default
  ) {
    self.release = release
    let root =
      installRootURL
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Compatibility", directoryHint: .isDirectory)
      .appending(path: "Socktainer", directoryHint: .isDirectory)
    installDirectoryURL = root.appending(path: release.version, directoryHint: .isDirectory)
    executableURL = installDirectoryURL.appending(
      path: "socktainer",
      directoryHint: .notDirectory
    )
    self.downloader = downloader
    self.validator = validator
    self.fileManager = fileManager
  }

  func installationState() async -> SocktainerInstallationState {
    guard fileManager.fileExists(atPath: executableURL.path(percentEncoded: false)) else {
      return .notInstalled
    }
    do {
      try validateInstallDirectory()
      try validator.validate(artifactURL: executableURL, release: release)
      return .ready(version: release.version)
    } catch {
      return .invalid(reason: error.localizedDescription)
    }
  }

  func install() async throws {
    try ensurePrivateInstallDirectory()

    let downloadedURL = try await downloader.download(
      from: release.sourceURL,
      maximumByteCount: release.maximumByteCount
    )
    defer { try? fileManager.removeItem(at: downloadedURL) }

    try validator.validate(artifactURL: downloadedURL, release: release)

    let stagingURL = installDirectoryURL.appending(
      path: ".socktainer-\(UUID().uuidString.lowercased()).tmp",
      directoryHint: .notDirectory
    )
    defer { try? fileManager.removeItem(at: stagingURL) }

    try fileManager.copyItem(at: downloadedURL, to: stagingURL)
    guard chmod(stagingURL.nativeContainersPOSIXPath, 0o700) == 0 else {
      throw DockerCompatibilityError.unsafeInstallLocation(
        stagingURL.path(percentEncoded: false)
      )
    }
    try validator.validate(artifactURL: stagingURL, release: release)

    let result = stagingURL.nativeContainersPOSIXPath.withCString { source in
      executableURL.nativeContainersPOSIXPath.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw DockerCompatibilityError.unsafeInstallLocation(
        executableURL.path(percentEncoded: false)
      )
    }

    try validator.validate(artifactURL: executableURL, release: release)
  }

  private func ensurePrivateInstallDirectory() throws {
    let path = installDirectoryURL.nativeContainersPOSIXPath
    var metadata = stat()
    if lstat(path, &metadata) == 0 {
      try validateInstallDirectory()
    } else {
      guard errno == ENOENT else {
        throw DockerCompatibilityError.unsafeInstallLocation(path)
      }
      try fileManager.createDirectory(
        at: installDirectoryURL,
        withIntermediateDirectories: true
      )
      try validateInstallDirectory()
    }
    guard chmod(path, 0o700) == 0 else {
      throw DockerCompatibilityError.unsafeInstallLocation(
        installDirectoryURL.path(percentEncoded: false)
      )
    }
    try validateInstallDirectory()
  }

  private func validateInstallDirectory() throws {
    var metadata = stat()
    let path = installDirectoryURL.nativeContainersPOSIXPath
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw DockerCompatibilityError.unsafeInstallLocation(path)
    }
  }
}

struct URLSessionSocktainerArtifactDownloader: SocktainerArtifactDownloading {
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
  }

  func download(
    from sourceURL: URL,
    maximumByteCount: Int64
  ) async throws -> URL {
    guard sourceURL.scheme?.lowercased() == "https" else {
      throw DockerCompatibilityError.downloadResponse(0)
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
    guard let response = response as? HTTPURLResponse else {
      throw DockerCompatibilityError.downloadResponse(0)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw DockerCompatibilityError.downloadResponse(response.statusCode)
    }
    if response.expectedContentLength > maximumByteCount {
      throw DockerCompatibilityError.artifactTooLarge(response.expectedContentLength)
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0, byteCount <= maximumByteCount else {
      throw DockerCompatibilityError.artifactTooLarge(byteCount)
    }

    let retainedURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-socktainer-\(UUID().uuidString.lowercased()).download",
      directoryHint: .notDirectory
    )
    do {
      try FileManager.default.copyItem(at: temporaryURL, to: retainedURL)
      guard chmod(retainedURL.nativeContainersPOSIXPath, 0o600) == 0 else {
        throw DockerCompatibilityError.unsafeInstallLocation(
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

struct SocktainerArtifactValidator: SocktainerArtifactValidating {
  func validate(
    artifactURL: URL,
    release: SocktainerRelease
  ) throws {
    let path = artifactURL.standardizedFileURL.nativeContainersPOSIXPath
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_size <= release.maximumByteCount,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw DockerCompatibilityError.unsafeInstallLocation(path)
    }

    guard try sha256(of: artifactURL) == release.sha256 else {
      throw DockerCompatibilityError.artifactDigestMismatch
    }
    try validateCodeSignature(
      at: artifactURL,
      teamIdentifier: release.developerTeamIdentifier
    )
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

  private func validateCodeSignature(
    at url: URL,
    teamIdentifier: String
  ) throws {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        url as CFURL,
        SecCSFlags(rawValue: 0),
        &staticCode
      ) == errSecSuccess,
      let staticCode
    else {
      throw DockerCompatibilityError.artifactSignatureInvalid
    }

    let requirementText =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        requirementText as CFString,
        SecCSFlags(rawValue: 0),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      throw DockerCompatibilityError.artifactSignerMismatch
    }

    let status = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: 0),
      requirement
    )
    guard status == errSecSuccess else {
      if status == errSecCSReqFailed {
        throw DockerCompatibilityError.artifactSignerMismatch
      }
      throw DockerCompatibilityError.artifactSignatureInvalid
    }
  }
}
