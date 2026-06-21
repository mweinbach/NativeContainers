import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ImageBuildSecretServiceTests {
  @Test
  func vaultReviewsMetadataThenStreamsBinaryAndEmptyFilesOnce() async throws {
    let fixture = try SecretSourceFixture()
    let context = try fixture.directory(named: "context")
    let binary = Data([0x00, 0xFF, 0x7F, 0x41, 0x00])
    let binaryURL = try fixture.file(named: "binary.secret", data: binary)
    let emptyURL = try fixture.file(named: "empty.secret", data: Data())
    let reviewID = UUID()
    let vault = ImageBuildSecretVault()

    let preparation = try await vault.prepare(
      reviewID: reviewID,
      selections: [
        ImageBuildSecretSelection(id: "z-empty", sourceURL: emptyURL),
        ImageBuildSecretSelection(id: "a-binary", sourceURL: binaryURL),
      ],
      contextDirectory: context
    )
    let reviews = preparation.reviews

    #expect(reviews.map(\.id) == ["a-binary", "z-empty"])
    #expect(
      reviews.map(\.displayPath)
        == [
          (binaryURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
          (emptyURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
        ]
    )
    #expect(reviews.map(\.byteCount) == [Int64(binary.count), 0])

    let payload = try await vault.consume(
      reviewID: reviewID,
      reviewedSecrets: reviews
    )
    let expectedIDs = payload.ids
    let pipe = Pipe()
    try ContainerBuildSecretWire.write(
      payload,
      to: pipe.fileHandleForWriting.fileDescriptor
    )
    let values = try ContainerBuildSecretWire.read(
      from: pipe.fileHandleForReading.fileDescriptor,
      expectedIDs: expectedIDs
    )
    try? pipe.fileHandleForWriting.close()
    try? pipe.fileHandleForReading.close()

    try await values.consume { streamed in
      #expect(streamed["a-binary"] == binary)
      #expect(streamed["z-empty"] == Data())
    }

    await #expect(throws: ImageBuildSecretError.reviewUnavailable) {
      _ = try await vault.consume(
        reviewID: reviewID,
        reviewedSecrets: reviews
      )
    }
  }

  @Test
  func vaultRejectsAChangedSourceAndConsumesItsReview() async throws {
    let fixture = try SecretSourceFixture()
    let context = try fixture.directory(named: "context")
    let source = try fixture.file(named: "token.secret", data: Data("first".utf8))
    let reviewID = UUID()
    let vault = ImageBuildSecretVault()
    let preparation = try await vault.prepare(
      reviewID: reviewID,
      selections: [ImageBuildSecretSelection(id: "token", sourceURL: source)],
      contextDirectory: context
    )

    try Data("changed".utf8).write(to: source)
    #expect(Darwin.chmod(source.path(percentEncoded: false), 0o600) == 0)

    await #expect(throws: ImageBuildSecretError.sourceChanged("token")) {
      _ = try await vault.consume(
        reviewID: reviewID,
        reviewedSecrets: preparation.reviews
      )
    }
    await #expect(throws: ImageBuildSecretError.reviewUnavailable) {
      _ = try await vault.consume(
        reviewID: reviewID,
        reviewedSecrets: preparation.reviews
      )
    }
  }

  @Test
  func policyRejectsDuplicateInvalidAndContextResidentSecretsBeforeOpening() throws {
    let fixture = try SecretSourceFixture()
    let context = try fixture.directory(named: "context")
    let outside = fixture.root.appending(path: "outside.secret")
    let inside = context.appending(path: "inside.secret")

    #expect(
      throws: ImageBuildSecretError.duplicateIdentifier("token")
    ) {
      _ = try ImageBuildSecretPolicy.validate(
        [
          ImageBuildSecretSelection(id: "token", sourceURL: outside),
          ImageBuildSecretSelection(id: "token", sourceURL: outside),
        ],
        contextDirectory: context
      )
    }
    #expect(
      throws: ImageBuildSecretError.invalidIdentifier("bad=value")
    ) {
      _ = try ImageBuildSecretPolicy.validate(
        [ImageBuildSecretSelection(id: "bad=value", sourceURL: outside)],
        contextDirectory: context
      )
    }
    #expect(
      throws: ImageBuildSecretError.sourceInsideBuildContext("token")
    ) {
      _ = try ImageBuildSecretPolicy.validate(
        [ImageBuildSecretSelection(id: "token", sourceURL: inside)],
        contextDirectory: context
      )
    }
  }

  @Test
  func vaultRejectsWorldReadableSymbolicLinkAndFIFOSecretSources() async throws {
    let fixture = try SecretSourceFixture()
    let context = try fixture.directory(named: "context")
    let readable = try fixture.file(
      named: "readable.secret",
      data: Data("value".utf8),
      permissions: 0o644
    )
    let privateSource = try fixture.file(named: "private.secret", data: Data("value".utf8))
    let link = fixture.root.appending(path: "linked.secret")
    let fifo = fixture.root.appending(path: "fifo.secret")
    #expect(Darwin.mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
    #expect(
      Darwin.symlink(
        privateSource.path(percentEncoded: false),
        link.path(percentEncoded: false)
      ) == 0
    )
    let vault = ImageBuildSecretVault()

    await #expect(throws: ImageBuildSecretError.sourceNotPrivate("readable")) {
      _ = try await vault.prepare(
        reviewID: UUID(),
        selections: [
          ImageBuildSecretSelection(id: "readable", sourceURL: readable)
        ],
        contextDirectory: context
      )
    }
    await #expect(throws: ImageBuildSecretError.sourceUnavailable("linked")) {
      _ = try await vault.prepare(
        reviewID: UUID(),
        selections: [ImageBuildSecretSelection(id: "linked", sourceURL: link)],
        contextDirectory: context
      )
    }
    await #expect(throws: ImageBuildSecretError.sourceNotPrivate("fifo")) {
      _ = try await vault.prepare(
        reviewID: UUID(),
        selections: [ImageBuildSecretSelection(id: "fifo", sourceURL: fifo)],
        contextDirectory: context
      )
    }
  }

  @Test
  func selectedSecretHardLinkCannotEnterTheStagedContext() async throws {
    let fixture = try SecretSourceFixture()
    let context = try fixture.directory(named: "context")
    _ = try fixture.file(
      at: context.appending(path: "Dockerfile"),
      data: Data("FROM scratch\n".utf8)
    )
    let source = try fixture.file(named: "outside.secret", data: Data("sentinel".utf8))
    let stagingRoot = try fixture.directory(named: "staging")
    let linkedSource = context.appending(path: "copied.secret")
    let reviewID = UUID()
    let vault = ImageBuildSecretVault()
    let preparation = try await vault.prepare(
      reviewID: reviewID,
      selections: [ImageBuildSecretSelection(id: "token", sourceURL: source)],
      contextDirectory: context
    )

    #expect(
      Darwin.link(
        source.path(percentEncoded: false),
        linkedSource.path(percentEncoded: false)
      ) == 0
    )

    let stager = BuildContextStager(stagingRoot: stagingRoot)
    await #expect(
      throws: BuildContextStagingError.excludedSecretSource("copied.secret")
    ) {
      _ = try await stager.stage(
        sourceDirectory: context,
        dockerfile: nil,
        dockerignore: .conventional,
        excludingFileIdentities: preparation.excludedContextFiles
      )
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: stagingRoot,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
    await vault.discard(reviewID: reviewID)
  }

  @Test
  func invocationReaderPreservesAdjacentBinaryAndEmptySecretsWithoutWaitingForEOF() async throws {
    let payload = try makeSourcePayload([
      ("binary", Data([0x00, 0xFF, 0x42])),
      ("empty", Data()),
    ])
    let expectedIDs = payload.ids
    let request = makeSecretWorkerRequest(secretIDs: expectedIDs)
    let controlFrame = try ContainerBuildWorkerFrameCodec.encode(request)
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: controlFrame)
    try ContainerBuildSecretWire.write(
      payload,
      to: pipe.fileHandleForWriting.fileDescriptor
    )

    let writeHandle = pipe.fileHandleForWriting
    let delayedClose = Task.detached {
      try? await Task.sleep(for: .milliseconds(1_500))
      try? writeHandle.close()
    }
    let started = ContinuousClock.now
    let invocation = try await Task.detached {
      try ContainerBuildWorkerInvocationInput.read(
        from: pipe.fileHandleForReading.fileDescriptor
      )
    }.value
    let elapsed = started.duration(to: .now)
    delayedClose.cancel()
    try? writeHandle.close()
    try? pipe.fileHandleForReading.close()

    #expect(invocation.request == request)
    #expect(invocation.secrets.ids == expectedIDs)
    try await invocation.secrets.consume { values in
      #expect(values["binary"] == Data([0x00, 0xFF, 0x42]))
      #expect(values["empty"] == Data())
    }
    #expect(elapsed < .milliseconds(750))
  }

  @Test
  func sourcePayloadReleasesEntriesAfterItsSingleSuccessfulWrite() async throws {
    let payload = try makeSourcePayload([("token", Data("sentinel".utf8))])
    let expectedIDs = payload.ids
    let pipe = Pipe()

    try ContainerBuildSecretWire.write(
      payload,
      to: pipe.fileHandleForWriting.fileDescriptor
    )
    #expect(
      throws: ContainerBuildSecretTransportError.payloadAlreadyConsumed
    ) {
      try ContainerBuildSecretWire.write(
        payload,
        to: pipe.fileHandleForWriting.fileDescriptor
      )
    }

    let values = try ContainerBuildSecretWire.read(
      from: pipe.fileHandleForReading.fileDescriptor,
      expectedIDs: expectedIDs
    )
    try? pipe.fileHandleForWriting.close()
    try? pipe.fileHandleForReading.close()
    try await values.consume { streamed in
      #expect(streamed["token"] == Data("sentinel".utf8))
    }
  }

  @Test
  func readerRejectsAnEnvelopeWithoutTheFinalCommitMarker() async throws {
    let pipe = Pipe()
    var uncommitted = Data([
      0x00, 0x00, 0x00, 0x01,
      0x00, 0x05,
    ])
    uncommitted.append(contentsOf: "token".utf8)
    uncommitted.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x41])
    try pipe.fileHandleForWriting.write(contentsOf: uncommitted)
    try pipe.fileHandleForWriting.close()

    #expect(
      throws: ContainerBuildSecretTransportError.truncatedPayload
    ) {
      _ = try ContainerBuildSecretWire.read(
        from: pipe.fileHandleForReading.fileDescriptor,
        expectedIDs: ["token"]
      )
    }
    try? pipe.fileHandleForReading.close()
  }

  @Test
  func payloadLimitsAcceptExactBoundariesAndRejectTheNextByte() throws {
    let identifierAtLimit = "a" + String(repeating: "b", count: 127)
    let payload = try makeSourcePayload([
      (
        identifierAtLimit,
        Data(count: ImageBuildSecretPolicy.maximumSecretBytes)
      ),
      (
        "second",
        Data(count: ImageBuildSecretPolicy.maximumSecretBytes)
      ),
      (
        "third",
        Data(
          count:
            ImageBuildSecretPolicy.maximumTotalBytes
            - (2 * ImageBuildSecretPolicy.maximumSecretBytes)
        )
      ),
    ])
    #expect(payload.ids == [identifierAtLimit, "second", "third"].sorted())

    #expect(
      throws: ContainerBuildSecretTransportError.secretTooLarge(
        id: "oversized",
        byteCount: ImageBuildSecretPolicy.maximumSecretBytes + 1,
        maximum: ImageBuildSecretPolicy.maximumSecretBytes
      )
    ) {
      _ = try makeSourcePayload([
        (
          "oversized",
          Data(count: ImageBuildSecretPolicy.maximumSecretBytes + 1)
        )
      ])
    }
    #expect(
      throws: ContainerBuildSecretTransportError.totalTooLarge(
        byteCount: ImageBuildSecretPolicy.maximumTotalBytes + 1,
        maximum: ImageBuildSecretPolicy.maximumTotalBytes
      )
    ) {
      _ = try makeSourcePayload([
        ("first", Data(count: ImageBuildSecretPolicy.maximumSecretBytes)),
        ("second", Data(count: ImageBuildSecretPolicy.maximumSecretBytes)),
        (
          "third",
          Data(
            count:
              ImageBuildSecretPolicy.maximumTotalBytes
              - (2 * ImageBuildSecretPolicy.maximumSecretBytes) + 1
          )
        ),
      ])
    }
    #expect(
      throws: ContainerBuildSecretTransportError.invalidIdentifier(
        "a" + String(repeating: "b", count: 128)
      )
    ) {
      _ = try makeSourcePayload([
        (
          "a" + String(repeating: "b", count: 128),
          Data()
        )
      ])
    }
  }

  @Test
  func controlJSONContainsIDsButNeverSecretBytesOrBase64() throws {
    let sentinel = Data("super-secret-sentinel".utf8)
    let payload = try makeSourcePayload([("token", sentinel)])
    let request = makeSecretWorkerRequest(secretIDs: payload.ids)
    let control = try JSONEncoder().encode(request)
    let text = String(decoding: control, as: UTF8.self)

    #expect(text.contains("\"secretIDs\":[\"token\"]"))
    #expect(!text.contains("super-secret-sentinel"))
    #expect(!text.contains(sentinel.base64EncodedString()))
  }
}

private final class TestSecretStreamingEntry:
  ContainerBuildSecretStreamingEntry, @unchecked Sendable
{
  let id: String
  let data: Data

  var byteCount: Int { data.count }

  init(id: String, data: Data) {
    self.id = id
    self.data = data
  }

  func writeBytes(to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let result = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: errno)
        }
        guard result > 0 else {
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: EIO)
        }
        offset += result
      }
    }
  }
}

private final class SecretSourceFixture: @unchecked Sendable {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-secret-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func directory(named name: String) throws -> URL {
    let url = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return url
  }

  func file(
    named name: String,
    data: Data,
    permissions: mode_t = 0o600
  ) throws -> URL {
    try file(
      at: root.appending(path: name, directoryHint: .notDirectory),
      data: data,
      permissions: permissions
    )
  }

  func file(
    at url: URL,
    data: Data,
    permissions: mode_t = 0o600
  ) throws -> URL {
    try data.write(to: url)
    guard Darwin.chmod(url.path(percentEncoded: false), permissions) == 0 else {
      throw ImageBuildSecretError.sourceUnavailable(url.lastPathComponent)
    }
    return url
  }
}

private func makeSourcePayload(
  _ values: [(String, Data)]
) throws -> ContainerBuildSecretSourcePayload {
  try ContainerBuildSecretSourcePayload(
    entries: values.map {
      TestSecretStreamingEntry(id: $0.0, data: $0.1)
        as any ContainerBuildSecretStreamingEntry
    }
  )
}

private func makeSecretWorkerRequest(
  secretIDs: [String]
) -> ContainerBuildWorkerRequest {
  ContainerBuildWorkerRequest(
    operation: .build,
    build: ContainerBuildWorkerBuildRequest(
      buildID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
      contextPath: "/tmp/nativecontainers-secret-worker/context",
      dockerfilePath: "/tmp/nativecontainers-secret-worker/context/Dockerfile",
      dockerfileSHA256: String(repeating: "a", count: 64),
      contextFingerprint: String(repeating: "b", count: 64),
      dockerignorePath: nil,
      dockerignoreSHA256: nil,
      tags: [
        ContainerBuildTagExpectation(
          reference: "nativecontainers.local/secret-test:latest",
          existingDigest: nil
        )
      ],
      platforms: [.current],
      buildArguments: [],
      labels: [],
      targetStage: "",
      cachePolicy: .disabled,
      pullLatest: false,
      secretIDs: secretIDs,
      allowsTagReplacement: false
    )
  )
}
