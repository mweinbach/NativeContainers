import CryptoKit
import Darwin
import Foundation

struct WindowsGuestToolsReleaseContract: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let version: String
  let artifactURL: URL?
  let sha256: String?
  let byteCount: UInt64?
  let isMicrosoftSigned: Bool
  let sourceRepositoryURL: URL
}

protocol WindowsGuestToolsReleaseContractLoading: Sendable {
  func load() throws -> WindowsGuestToolsReleaseContract
}

protocol WindowsGuestToolsDownloading: Sendable {
  func download(from sourceURL: URL, to destinationURL: URL) async throws
}

protocol WindowsGuestToolsReleaseManaging: Sendable {
  func prepareProductionRelease() async throws -> WindowsGuestToolsReleaseReference
}

protocol WindowsGuestToolsArtifactVerifying: Sendable {
  func verify(
    _ artifactURL: URL,
    against release: WindowsGuestToolsReleaseReference
  ) throws
}

struct BundledWindowsGuestToolsReleaseContractLoader:
  WindowsGuestToolsReleaseContractLoading,
  @unchecked Sendable
{
  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
  }

  func load() throws -> WindowsGuestToolsReleaseContract {
    guard
      let url = bundle.url(
        forResource: "WindowsGuestToolsReleaseContract",
        withExtension: "json"
      )
    else {
      throw WindowsGuestToolsReleaseError.missingContract
    }
    do {
      return try JSONDecoder().decode(
        WindowsGuestToolsReleaseContract.self,
        from: Data(contentsOf: url)
      )
    } catch {
      throw WindowsGuestToolsReleaseError.invalidContract(
        error.localizedDescription
      )
    }
  }
}

actor URLSessionWindowsGuestToolsDownloader: WindowsGuestToolsDownloading {
  private let session: URLSession
  private let fileManager: FileManager

  init(
    session: URLSession = .shared,
    fileManager: FileManager = .default
  ) {
    self.session = session
    self.fileManager = fileManager
  }

  func download(from sourceURL: URL, to destinationURL: URL) async throws {
    let (temporaryURL, response) = try await session.download(from: sourceURL)
    if let response = response as? HTTPURLResponse {
      guard (200..<300).contains(response.statusCode) else {
        throw WindowsGuestToolsReleaseError.downloadFailed(
          "HTTP \(response.statusCode)"
        )
      }
    }
    do {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    } catch {
      throw WindowsGuestToolsReleaseError.downloadFailed(
        error.localizedDescription
      )
    }
  }
}

struct WindowsGuestToolsArtifactVerifier: WindowsGuestToolsArtifactVerifying {
  static let readChunkSize = 4 * 1_024 * 1_024

  func verify(
    _ artifactURL: URL,
    against release: WindowsGuestToolsReleaseReference
  ) throws {
    let descriptor = Darwin.open(
      artifactURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw WindowsGuestToolsReleaseError.invalidArtifact(
        "the cached ISO is missing or unsafe"
      )
    }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? input.close() }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_size >= 0,
      UInt64(metadata.st_size) == release.byteCount
    else {
      throw WindowsGuestToolsReleaseError.invalidArtifact(
        "the cached ISO size does not match the release contract"
      )
    }

    var hasher = SHA256()
    while let data = try input.read(upToCount: Self.readChunkSize), !data.isEmpty {
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
      throw WindowsGuestToolsReleaseError.invalidArtifact(
        "the cached ISO checksum does not match the release contract"
      )
    }
  }
}

struct WindowsGuestToolsCache: @unchecked Sendable {
  static let artifactFilename = "NCTools.iso"

  private let rootURL: URL
  private let fileManager: FileManager
  private let verifier: any WindowsGuestToolsArtifactVerifying

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    verifier: any WindowsGuestToolsArtifactVerifying =
      WindowsGuestToolsArtifactVerifier()
  ) {
    self.fileManager = fileManager
    self.verifier = verifier
    self.rootURL =
      rootURL
      ?? fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Windows Guest Tools", directoryHint: .isDirectory)
  }

  func resolve(_ release: WindowsGuestToolsReleaseReference) throws -> URL {
    let artifactURL = try artifactURL(for: release)
    try verifier.verify(artifactURL, against: release)
    return artifactURL
  }

  func validArtifact(
    for release: WindowsGuestToolsReleaseReference
  ) throws -> URL? {
    let artifactURL = try artifactURL(for: release)
    guard fileManager.fileExists(atPath: artifactURL.path) else { return nil }
    do {
      try verifier.verify(artifactURL, against: release)
      return artifactURL
    } catch {
      try fileManager.removeItem(at: artifactURL)
      return nil
    }
  }

  func makeStagingURL(
    for release: WindowsGuestToolsReleaseReference
  ) throws -> URL {
    let directory = try releaseDirectory(for: release)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory.appending(
      path: ".download-\(UUID().uuidString.lowercased()).partial"
    )
  }

  func commit(
    stagingURL: URL,
    release: WindowsGuestToolsReleaseReference
  ) throws -> URL {
    try verifier.verify(stagingURL, against: release)
    let destinationURL = try artifactURL(for: release)
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw WindowsGuestToolsReleaseError.cacheCollision(destinationURL)
    }
    try fileManager.moveItem(at: stagingURL, to: destinationURL)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    try verifier.verify(destinationURL, against: release)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDestinationURL = destinationURL
    try? mutableDestinationURL.setResourceValues(values)
    return destinationURL
  }

  func discardStagingURL(_ stagingURL: URL) {
    try? fileManager.removeItem(at: stagingURL)
  }

  private func artifactURL(
    for release: WindowsGuestToolsReleaseReference
  ) throws -> URL {
    try releaseDirectory(for: release).appending(path: Self.artifactFilename)
  }

  private func releaseDirectory(
    for release: WindowsGuestToolsReleaseReference
  ) throws -> URL {
    guard Self.isSafePathComponent(release.version) else {
      throw WindowsGuestToolsReleaseError.invalidContract(
        "the release version is not a safe cache path"
      )
    }
    return rootURL.appending(path: release.version, directoryHint: .isDirectory)
  }

  private static func isSafePathComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
      }
  }
}

actor WindowsGuestToolsReleaseManager: WindowsGuestToolsReleaseManaging {
  private let contractLoader: any WindowsGuestToolsReleaseContractLoading
  private let downloader: any WindowsGuestToolsDownloading
  private let cache: WindowsGuestToolsCache

  init(
    contractLoader: any WindowsGuestToolsReleaseContractLoading =
      BundledWindowsGuestToolsReleaseContractLoader(),
    downloader: any WindowsGuestToolsDownloading =
      URLSessionWindowsGuestToolsDownloader(),
    cache: WindowsGuestToolsCache = WindowsGuestToolsCache()
  ) {
    self.contractLoader = contractLoader
    self.downloader = downloader
    self.cache = cache
  }

  func prepareProductionRelease() async throws -> WindowsGuestToolsReleaseReference {
    let contract = try contractLoader.load()
    let release = try productionRelease(from: contract)
    if try cache.validArtifact(for: release) != nil {
      return release
    }

    let stagingURL = try cache.makeStagingURL(for: release)
    do {
      try await downloader.download(
        from: release.artifactURL,
        to: stagingURL
      )
      _ = try cache.commit(stagingURL: stagingURL, release: release)
      return release
    } catch {
      cache.discardStagingURL(stagingURL)
      throw error
    }
  }

  private func productionRelease(
    from contract: WindowsGuestToolsReleaseContract
  ) throws -> WindowsGuestToolsReleaseReference {
    guard contract.schemaVersion == WindowsGuestToolsReleaseContract.currentSchemaVersion
    else {
      throw WindowsGuestToolsReleaseError.unsupportedSchema(
        contract.schemaVersion
      )
    }
    guard contract.isMicrosoftSigned else {
      throw WindowsVirtualMachineError.productionGuestToolsUnavailable
    }
    guard let artifactURL = contract.artifactURL,
      artifactURL.scheme?.lowercased() == "https",
      let sha256 = contract.sha256?.lowercased(),
      sha256.count == 64,
      sha256.allSatisfy(\.isHexDigit),
      let byteCount = contract.byteCount,
      byteCount > 0
    else {
      throw WindowsGuestToolsReleaseError.invalidContract(
        "the production artifact URL, checksum, or byte count is invalid"
      )
    }
    return WindowsGuestToolsReleaseReference(
      version: contract.version,
      artifactURL: artifactURL,
      sha256: sha256,
      byteCount: byteCount,
      isMicrosoftSigned: true
    )
  }
}

enum WindowsGuestToolsReleaseError: LocalizedError, Equatable {
  case missingContract
  case unsupportedSchema(Int)
  case invalidContract(String)
  case downloadFailed(String)
  case invalidArtifact(String)
  case cacheCollision(URL)

  var errorDescription: String? {
    switch self {
    case .missingContract:
      "The bundled Windows guest-tools release contract is missing."
    case .unsupportedSchema(let version):
      "The Windows guest-tools release contract uses unsupported schema \(version)."
    case .invalidContract(let reason):
      "The Windows guest-tools release contract is invalid: \(reason)"
    case .downloadFailed(let reason):
      "Windows guest tools could not be downloaded: \(reason)"
    case .invalidArtifact(let reason):
      "Windows guest tools failed integrity verification: \(reason)"
    case .cacheCollision(let url):
      "A Windows guest-tools artifact already exists at \(url.path)."
    }
  }
}
