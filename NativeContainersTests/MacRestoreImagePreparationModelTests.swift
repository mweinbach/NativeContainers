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
    let downloader = TestRestoreImageDownloader(localURL: localURL)
    let recorder = PreparedURLRecorder()
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(info: info),
      downloader: downloader
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
    #expect(await downloader.requestedURLs == [remoteURL])
    #expect(await recorder.urls == [localURL])
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
    let downloader = TestRestoreImageDownloader(localURL: URL(filePath: "/tmp/macOS.ipsw"))
    let model = MacRestoreImagePreparationModel(
      machine: machine,
      discovery: TestRestoreImageDiscovery(info: info),
      downloader: downloader
    ) { _ in
      Issue.record("An incompatible restore image must not be prepared.")
    }

    await model.discoverLatest()
    let succeeded = await model.downloadLatestAndPrepare()

    #expect(!succeeded)
    #expect(model.latestImageCompatibilityMessage?.contains("at least 4 CPUs") == true)
    #expect(model.errorMessage == model.latestImageCompatibilityMessage)
    #expect(await downloader.requestedURLs.isEmpty)
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

private actor TestRestoreImageDownloader: MacRestoreImageDownloading {
  let localURL: URL
  private(set) var requestedURLs: [URL] = []

  init(localURL: URL) {
    self.localURL = localURL
  }

  func download(
    from sourceURL: URL,
    progress: @escaping RestoreImageDownloadProgressHandler
  ) async throws -> URL {
    requestedURLs.append(sourceURL)
    await progress(
      RestoreImageDownloadProgress(
        receivedBytes: 8,
        totalBytes: 8
      )
    )
    return localURL
  }
}

private actor PreparedURLRecorder {
  private(set) var urls: [URL] = []

  func record(_ url: URL) {
    urls.append(url)
  }
}
