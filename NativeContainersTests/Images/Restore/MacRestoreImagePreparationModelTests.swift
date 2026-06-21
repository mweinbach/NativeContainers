import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacRestoreImagePreparationModelTests {
  @Test
  func discoversDownloadsAndPreparesLatestSupportedImage() async throws {
    let machine = try makeMachine()
    let remoteURL = URL(string: "https://example.test/macOS.ipsw")!
    let localURL = URL(filePath: "/tmp/macOS.ipsw")
    let info = MacRestoreImageInfo(
      url: remoteURL,
      buildVersion: "26A123",
      majorVersion: 26,
      minorVersion: 0,
      patchVersion: 0,
      minimumCPUCount: 4,
      minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      isSupported: true
    )
    let acquisition = TestRestoreImageAcquisition(cachedURL: localURL)
    let recorder = PreparedURLRecorder()
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(info: info),
      acquisition: acquisition
    ) { url in
      await recorder.record(url)
    }

    await model.discoverLatest()
    let succeeded = await model.downloadLatestAndPrepare()

    #expect(model.latestImage == info)
    #expect(succeeded)
    #expect(model.stage == .finished)
    #expect(model.downloadProgress?.fractionCompleted == 1)
    #expect(model.errorMessage == nil)
    #expect(await acquisition.requestedSources == [.remote(remoteURL)])
    #expect(await acquisition.committedURLs == [localURL])
    #expect(await recorder.urls == [localURL])
  }

  @Test
  func cacheLeaseStaysOwnedUntilPlatformPreparationReturns() async throws {
    let machine = try makeMachine()
    let remoteURL = URL(string: "https://example.test/leased.ipsw")!
    let cachedURL = URL(filePath: "/private/cache/leased.ipsw")
    let acquisition = TestRestoreImageAcquisition(cachedURL: cachedURL)
    let gate = RestoreImagePreparationGate()
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(
        info: MacRestoreImageInfo(
          url: remoteURL,
          buildVersion: "26A123",
          majorVersion: 26,
          minorVersion: 0,
          patchVersion: 0,
          minimumCPUCount: 4,
          minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
          isSupported: true
        )
      ),
      acquisition: acquisition
    ) { _ in
      await gate.pause()
    }

    await model.discoverLatest()
    let preparation = Task { await model.downloadLatestAndPrepare() }
    await gate.waitUntilPaused()

    #expect(await acquisition.committedURLs.isEmpty)
    #expect(await acquisition.abandonedURLs.isEmpty)

    await gate.resume()
    #expect(await preparation.value)
    #expect(await acquisition.committedURLs == [cachedURL])
  }

  @Test
  func incompatibleLatestImageDoesNotStartDownload() async throws {
    let machine = try makeMachine(cpuCount: 2)
    let info = MacRestoreImageInfo(
      url: URL(string: "https://example.test/macOS.ipsw")!,
      buildVersion: "26A123",
      majorVersion: 26,
      minorVersion: 0,
      patchVersion: 0,
      minimumCPUCount: 4,
      minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      isSupported: true
    )
    let acquisition = TestRestoreImageAcquisition(
      cachedURL: URL(filePath: "/tmp/macOS.ipsw")
    )
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(info: info),
      acquisition: acquisition
    ) { _ in
      Issue.record("An incompatible restore image must not be prepared.")
    }

    await model.discoverLatest()
    let succeeded = await model.downloadLatestAndPrepare()

    #expect(!succeeded)
    #expect(model.latestImageCompatibilityMessage?.contains("at least 4 CPUs") == true)
    #expect(model.errorMessage == model.latestImageCompatibilityMessage)
    #expect(await acquisition.requestedSources.isEmpty)
  }

  @Test
  func localImageIsImportedBeforePlatformPreparation() async throws {
    let machine = try makeMachine()
    let selectedURL = URL(filePath: "/tmp/Selected.ipsw")
    let importedURL = URL(filePath: "/private/cache/Imported.ipsw")
    let acquisition = TestRestoreImageAcquisition(cachedURL: importedURL)
    let recorder = PreparedURLRecorder()
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(
        info: MacRestoreImageInfo(
          url: URL(string: "https://example.test/macOS.ipsw")!,
          buildVersion: "26A123",
          majorVersion: 26,
          minorVersion: 0,
          patchVersion: 0,
          minimumCPUCount: 4,
          minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
          isSupported: true
        )
      ),
      acquisition: acquisition
    ) { url in
      await recorder.record(url)
    }

    let succeeded = await model.prepareLocalImage(at: selectedURL)

    #expect(succeeded)
    #expect(model.stage == .finished)
    #expect(await acquisition.requestedSources == [.local(selectedURL)])
    #expect(await acquisition.committedURLs == [importedURL])
    #expect(await acquisition.abandonedURLs.isEmpty)
    #expect(await recorder.urls == [importedURL])
  }

  @Test
  func localPreparationFailureDiscardsImportedCacheCopy() async throws {
    let machine = try makeMachine()
    let selectedURL = URL(filePath: "/tmp/Selected.ipsw")
    let importedURL = URL(filePath: "/private/cache/Imported.ipsw")
    let acquisition = TestRestoreImageAcquisition(cachedURL: importedURL)
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(
        info: MacRestoreImageInfo(
          url: URL(string: "https://example.test/macOS.ipsw")!,
          buildVersion: "26A123",
          majorVersion: 26,
          minorVersion: 0,
          patchVersion: 0,
          minimumCPUCount: 4,
          minimumMemoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
          isSupported: true
        )
      ),
      acquisition: acquisition
    ) { _ in
      throw TestRestoreImagePreparationError.expected
    }

    let succeeded = await model.prepareLocalImage(at: selectedURL)

    #expect(!succeeded)
    #expect(await acquisition.abandonedURLs == [importedURL])
    #expect(await acquisition.committedURLs.isEmpty)
  }

  private func makeMachine(cpuCount: Int = 4) throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: "Development Mac",
      guest: .macOS,
      resources: VirtualMachineResources(
        cpuCount: cpuCount,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}

private struct TestRestoreImageDiscovery: MacRestoreImageDiscovering {
  let info: MacRestoreImageInfo

  func latestSupported() async throws -> MacRestoreImageInfo {
    info
  }
}

private enum TestRestoreImagePreparationError: Error {
  case expected
}

private actor TestRestoreImageAcquisition: RestoreImageAcquiring {
  let cachedURL: URL
  private(set) var requestedSources: [RestoreImageAcquisitionSource] = []
  private(set) var committedURLs: [URL] = []
  private(set) var abandonedURLs: [URL] = []

  init(cachedURL: URL) {
    self.cachedURL = cachedURL
  }

  func acquire(
    _ source: RestoreImageAcquisitionSource,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> RestoreImageCacheLease {
    requestedSources.append(source)
    await progress(RestoreImageDownloadProgress(receivedBytes: 8, totalBytes: 8))
    switch source {
    case .remote:
      return RestoreImageCacheLease(
        fileURL: cachedURL,
        purpose: .remoteDownload,
        abandonPolicy: .retainArtifacts
      )
    case .local:
      return RestoreImageCacheLease(
        fileURL: cachedURL,
        purpose: .localImport,
        abandonPolicy: .discardArtifacts
      )
    }
  }

  func commit(_ lease: RestoreImageCacheLease) {
    committedURLs.append(lease.fileURL)
  }

  func abandon(_ lease: RestoreImageCacheLease) throws {
    abandonedURLs.append(lease.fileURL)
  }

}

private actor PreparedURLRecorder {
  private(set) var urls: [URL] = []

  func record(_ url: URL) {
    urls.append(url)
  }
}

private actor RestoreImagePreparationGate {
  private var isPaused = false
  private var pauseContinuation: CheckedContinuation<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func pause() async {
    isPaused = true
    let waiters = waiters
    self.waiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      pauseContinuation = continuation
    }
  }

  func waitUntilPaused() async {
    guard !isPaused else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func resume() {
    isPaused = false
    pauseContinuation?.resume()
    pauseContinuation = nil
  }
}
