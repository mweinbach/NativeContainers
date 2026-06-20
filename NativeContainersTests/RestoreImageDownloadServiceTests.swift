import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct RestoreImageDownloadServiceTests {
  @Test
  func downloadsFreshImageAndAtomicallyPromotesPartialFile() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    let body = Data("restore-image".utf8)
    await StubURLProtocol.registry.register(
      StubResponse(statusCode: 200, chunks: [body]),
      for: sourceURL
    )
    let progress = ProgressRecorder()

    let downloadedURL = try await fixture.service.download(from: sourceURL) { update in
      await progress.record(update)
    }

    #expect(downloadedURL == fixture.destinationURL)
    #expect(try Data(contentsOf: downloadedURL) == body)
    #expect(!FileManager.default.fileExists(atPath: fixture.partialURL.path))
    let updates = await progress.updates
    #expect(!updates.isEmpty)
    #expect(
      updates.allSatisfy { update in
        update.receivedBytes >= 0
          && update.receivedBytes <= (update.totalBytes ?? Int64.max)
          && (update.fractionCompleted.map { 0...1 ~= $0 } ?? true)
      }
    )
    #expect(updates.last?.fractionCompleted == 1)
  }

  @Test
  func resumesWithRangeAndAppendsAValidatedPartialResponse() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    try Data("hello ".utf8).write(to: fixture.partialURL)
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    await StubURLProtocol.registry.register(
      StubResponse(
        statusCode: 206,
        headers: ["Content-Range": "bytes 6-10/11"],
        chunks: [Data("world".utf8)]
      ),
      for: sourceURL
    )

    let result = try await fixture.service.download(
      from: sourceURL,
      to: fixture.destinationURL
    ) { _ in }

    #expect(result.resumedFromBytes == 6)
    #expect(result.byteCount == 11)
    #expect(try Data(contentsOf: result.fileURL) == Data("hello world".utf8))
    let requests = await StubURLProtocol.registry.requests(for: sourceURL)
    #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=6-")
  }

  @Test
  func restartsWhenServerIgnoresRangeRequest() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    try Data("stale-prefix".utf8).write(to: fixture.partialURL)
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    let replacement = Data("complete-new-image".utf8)
    await StubURLProtocol.registry.register(
      StubResponse(statusCode: 200, chunks: [replacement]),
      for: sourceURL
    )

    let result = try await fixture.service.download(
      from: sourceURL,
      to: fixture.destinationURL
    ) { _ in }

    #expect(result.resumedFromBytes == 0)
    #expect(try Data(contentsOf: result.fileURL) == replacement)
    let requests = await StubURLProtocol.registry.requests(for: sourceURL)
    #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=12-")
  }

  @Test
  func rejectsMismatchedContentRangeWithoutChangingPartialFile() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    let existing = Data("partial".utf8)
    try existing.write(to: fixture.partialURL)
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    await StubURLProtocol.registry.register(
      StubResponse(
        statusCode: 206,
        headers: ["Content-Range": "bytes 0-3/4"],
        chunks: [Data("oops".utf8)]
      ),
      for: sourceURL
    )

    await #expect(throws: RestoreImageDownloadError.invalidContentRange("bytes 0-3/4")) {
      _ = try await fixture.service.download(
        from: sourceURL,
        to: fixture.destinationURL
      ) { _ in }
    }

    #expect(try Data(contentsOf: fixture.partialURL) == existing)
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
  }

  @Test
  func cancellationKeepsNewlyDownloadedBytesInPartialFile() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    let firstChunk = Data(repeating: 0xAB, count: 32 * 1_024)
    await StubURLProtocol.registry.register(
      StubResponse(
        statusCode: 200,
        headers: ["Content-Length": "65536"],
        chunks: [firstChunk],
        completionDelay: .seconds(60)
      ),
      for: sourceURL
    )
    let progress = ProgressRecorder()
    let download = Task {
      try await fixture.service.download(
        from: sourceURL,
        to: fixture.destinationURL
      ) { update in
        await progress.record(update)
      }
    }

    try await waitUntil {
      await progress.updates.contains { $0.receivedBytes >= Int64(firstChunk.count) }
    }
    download.cancel()
    do {
      _ = try await download.value
      Issue.record("Expected the restore-image download to be cancelled.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, got \(error).")
    }

    #expect(try Data(contentsOf: fixture.partialURL) == firstChunk)
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
  }

  @Test
  func successfulDownloadAtomicallyReplacesExistingFinalFile() async throws {
    let fixture = try DownloadFixture()
    defer { fixture.remove() }
    try Data("old-image".utf8).write(to: fixture.destinationURL)
    let sourceURL = URL(string: "https://example.test/Restore.ipsw")!
    let newImage = Data("new-image".utf8)
    await StubURLProtocol.registry.register(
      StubResponse(statusCode: 200, chunks: [newImage]),
      for: sourceURL
    )

    _ = try await fixture.service.download(
      from: sourceURL,
      to: fixture.destinationURL
    ) { _ in }

    #expect(try Data(contentsOf: fixture.destinationURL) == newImage)
    #expect(!FileManager.default.fileExists(atPath: fixture.partialURL.path))
  }
}

private struct DownloadFixture {
  let rootURL: URL
  let destinationURL: URL
  let partialURL: URL
  let service: RestoreImageDownloadService

  init() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let destinationURL = rootURL.appending(path: "Restore.ipsw")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]

    self.rootURL = rootURL
    self.destinationURL = destinationURL
    self.partialURL = RestoreImageDownloadService.partialFileURL(for: destinationURL)
    self.service = RestoreImageDownloadService(
      downloadDirectoryURL: rootURL,
      sessionConfiguration: configuration
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private actor ProgressRecorder {
  private(set) var updates: [RestoreImageDownloadProgress] = []

  func record(_ update: RestoreImageDownloadProgress) {
    updates.append(update)
  }
}

private struct StubResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let chunks: [Data]
  let completionDelay: Duration?

  init(
    statusCode: Int,
    headers: [String: String] = [:],
    chunks: [Data],
    completionDelay: Duration? = nil
  ) {
    self.statusCode = statusCode
    var headers = headers
    if headers["Content-Length"] == nil {
      headers["Content-Length"] = String(chunks.reduce(0) { $0 + $1.count })
    }
    self.headers = headers
    self.chunks = chunks
    self.completionDelay = completionDelay
  }
}

private actor StubURLProtocolRegistry {
  private var responses: [URL: StubResponse] = [:]
  private var recordedRequests: [URL: [URLRequest]] = [:]

  func register(_ response: StubResponse, for url: URL) {
    responses[url] = response
    recordedRequests[url] = []
  }

  func response(for request: URLRequest) throws -> StubResponse {
    guard let url = request.url, let response = responses[url] else {
      throw URLError(.resourceUnavailable)
    }
    recordedRequests[url, default: []].append(request)
    return response
  }

  func requests(for url: URL) -> [URLRequest] {
    recordedRequests[url, default: []]
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  static let registry = StubURLProtocolRegistry()

  private var loadingTask: Task<Void, Never>?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    loadingTask = Task {
      do {
        let stub = try await Self.registry.response(for: request)
        guard
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
          )
        else {
          throw URLError(.badServerResponse)
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
          try Task.checkCancellation()
          client?.urlProtocol(self, didLoad: chunk)
        }
        if let completionDelay = stub.completionDelay {
          try await Task.sleep(for: completionDelay)
        }
        try Task.checkCancellation()
        client?.urlProtocolDidFinishLoading(self)
      } catch is CancellationError {
        // URLSession reports cancellation to its task delegate.
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {
    loadingTask?.cancel()
    loadingTask = nil
  }
}

private func waitUntil(
  timeout: Duration = .seconds(2),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw TestWaitError.timedOut
}

private enum TestWaitError: Error {
  case timedOut
}
