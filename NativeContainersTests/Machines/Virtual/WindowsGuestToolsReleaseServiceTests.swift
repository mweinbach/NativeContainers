import CryptoKit
import Foundation
import Testing

@testable import NativeContainers

struct WindowsGuestToolsReleaseServiceTests {
  @Test
  func unsignedContractHardGatesProductionWithoutDownloading() async throws {
    let fixture = try WindowsGuestToolsFixture()
    defer { fixture.remove() }
    let downloader = RecordingWindowsGuestToolsDownloader(data: Data([1]))
    let manager = WindowsGuestToolsReleaseManager(
      contractLoader: StaticWindowsGuestToolsContractLoader(
        contract: fixture.contract(isMicrosoftSigned: false)
      ),
      downloader: downloader,
      cache: WindowsGuestToolsCache(rootURL: fixture.cache)
    )

    await #expect(throws: WindowsVirtualMachineError.productionGuestToolsUnavailable) {
      try await manager.prepareProductionRelease()
    }
    #expect(await downloader.downloadCount() == 0)
  }

  @Test
  func unvalidatedSecureBootHardGatesSignedReleaseWithoutDownloading() async throws {
    let fixture = try WindowsGuestToolsFixture()
    defer { fixture.remove() }
    let downloader = RecordingWindowsGuestToolsDownloader(data: Data([1]))
    let manager = WindowsGuestToolsReleaseManager(
      contractLoader: StaticWindowsGuestToolsContractLoader(
        contract: fixture.contract(
          isMicrosoftSigned: true,
          isWindowsSecureBootValidated: false
        )
      ),
      downloader: downloader,
      cache: WindowsGuestToolsCache(rootURL: fixture.cache)
    )

    await #expect(throws: WindowsVirtualMachineError.productionSecureBootUnvalidated) {
      try await manager.prepareProductionRelease()
    }
    #expect(await downloader.downloadCount() == 0)
  }

  @Test
  func signedReleaseDownloadsVerifiesAndReusesManagedCache() async throws {
    let fixture = try WindowsGuestToolsFixture()
    defer { fixture.remove() }
    let bytes = Data((0..<16_384).map { UInt8($0 % 251) })
    let downloader = RecordingWindowsGuestToolsDownloader(data: bytes)
    let manager = WindowsGuestToolsReleaseManager(
      contractLoader: StaticWindowsGuestToolsContractLoader(
        contract: fixture.contract(
          isMicrosoftSigned: true,
          data: bytes
        )
      ),
      downloader: downloader,
      cache: WindowsGuestToolsCache(rootURL: fixture.cache)
    )

    let first = try await manager.prepareProductionRelease()
    let second = try await manager.prepareProductionRelease()
    let cachedURL = try WindowsGuestToolsCache(rootURL: fixture.cache).resolve(first)

    #expect(first == second)
    #expect(try Data(contentsOf: cachedURL) == bytes)
    #expect(await downloader.downloadCount() == 1)
  }

  @Test
  func corruptCachedArtifactIsRemovedAndReplaced() async throws {
    let fixture = try WindowsGuestToolsFixture()
    defer { fixture.remove() }
    let bytes = Data("signed-tools".utf8)
    let contract = fixture.contract(isMicrosoftSigned: true, data: bytes)
    let release = try #require(fixture.release(from: contract))
    let releaseDirectory = fixture.cache.appending(
      path: release.version,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: releaseDirectory,
      withIntermediateDirectories: true
    )
    try Data("corrupt".utf8).write(
      to: releaseDirectory.appending(path: WindowsGuestToolsCache.artifactFilename)
    )
    let downloader = RecordingWindowsGuestToolsDownloader(data: bytes)
    let manager = WindowsGuestToolsReleaseManager(
      contractLoader: StaticWindowsGuestToolsContractLoader(contract: contract),
      downloader: downloader,
      cache: WindowsGuestToolsCache(rootURL: fixture.cache)
    )

    let prepared = try await manager.prepareProductionRelease()

    #expect(try WindowsGuestToolsCache(rootURL: fixture.cache).resolve(prepared).isFileURL)
    #expect(await downloader.downloadCount() == 1)
  }
}

private struct StaticWindowsGuestToolsContractLoader:
  WindowsGuestToolsReleaseContractLoading
{
  let contract: WindowsGuestToolsReleaseContract

  func load() -> WindowsGuestToolsReleaseContract {
    contract
  }
}

private actor RecordingWindowsGuestToolsDownloader: WindowsGuestToolsDownloading {
  private let data: Data
  private var count = 0

  init(data: Data) {
    self.data = data
  }

  func download(from sourceURL: URL, to destinationURL: URL) throws {
    count += 1
    try data.write(to: destinationURL)
  }

  func downloadCount() -> Int {
    count
  }
}

private struct WindowsGuestToolsFixture {
  let root: URL
  let cache: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-WindowsGuestToolsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    cache = root.appending(path: "Cache", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  func contract(
    isMicrosoftSigned: Bool,
    isWindowsSecureBootValidated: Bool = true,
    data: Data = Data([1])
  ) -> WindowsGuestToolsReleaseContract {
    WindowsGuestToolsReleaseContract(
      schemaVersion: 1,
      version: "1.0.0",
      artifactURL: URL(string: "https://example.invalid/NCTools.iso"),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: UInt64(data.count),
      isMicrosoftSigned: isMicrosoftSigned,
      isWindowsSecureBootValidated: isWindowsSecureBootValidated,
      sourceRepositoryURL: URL(
        string: "https://github.com/example/NativeContainersWindowsGuestTools"
      )!
    )
  }

  func release(
    from contract: WindowsGuestToolsReleaseContract
  ) -> WindowsGuestToolsReleaseReference? {
    guard let artifactURL = contract.artifactURL,
      let sha256 = contract.sha256,
      let byteCount = contract.byteCount
    else { return nil }
    return WindowsGuestToolsReleaseReference(
      version: contract.version,
      artifactURL: artifactURL,
      sha256: sha256,
      byteCount: byteCount,
      isMicrosoftSigned: contract.isMicrosoftSigned
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
