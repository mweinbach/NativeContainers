import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ContainerBuildWorkerFrameCodecTests {
  @Test
  func decodesFragmentedAndAdjacentFrames() throws {
    let first = FrameFixture(id: 1, text: "first")
    let second = FrameFixture(id: 2, text: "second")
    let stream =
      try ContainerBuildWorkerFrameCodec.encode(first)
      + ContainerBuildWorkerFrameCodec.encode(second)
    var decoder = ContainerBuildWorkerFrameDecoder<FrameFixture>()
    var decoded: [FrameFixture] = []

    for byte in stream {
      decoded += try decoder.append(Data([byte]))
    }
    try decoder.finish()

    #expect(decoded == [first, second])
  }

  @Test
  func protocolVersionSevenRoundTripsReviewedSSHWithoutSocketPaths() throws {
    let buildID = UUID()
    let build = ContainerBuildWorkerBuildRequest(
      buildID: buildID,
      outputKind: .rootFilesystemDirectory,
      contextPath: "/private/context",
      dockerfilePath: "/private/context/Dockerfile",
      dockerfileSHA256: String(repeating: "a", count: 64),
      contextFingerprint: String(repeating: "b", count: 64),
      dockerignorePath: nil,
      dockerignoreSHA256: nil,
      tags: [],
      platforms: [.current],
      buildArguments: [],
      labels: [],
      targetStage: "",
      cachePolicy: .appOwnedLocalV1,
      remoteCache: ContainerBuildRemoteCacheProfile(
        reference: "registry.example/nativecontainers/cache:reviewed",
        access: .importAndExport,
        exportMode: .maximum
      ),
      pullLatest: true,
      secretIDs: [],
      sshAgentIDs: ["default"],
      allowsTagReplacement: false
    )
    let request = ContainerBuildWorkerRequest(
      operation: .build,
      builder: ContainerBuilderConfiguration(
        cpuCount: nil,
        memoryMiB: nil,
        forwardsSSHAgent: true,
        allowsRecreateStoppedBuilder: false,
        allowsStopRunningBuilder: false
      ),
      build: build
    )
    let encodedRequest = try JSONEncoder().encode(request)
    let decodedRequest = try JSONDecoder().decode(
      ContainerBuildWorkerRequest.self,
      from: encodedRequest
    )
    let requestJSON = try #require(
      JSONSerialization.jsonObject(with: encodedRequest) as? [String: Any]
    )
    let buildJSON = try #require(requestJSON["build"] as? [String: Any])

    #expect(ContainerBuildWorkerRequest.currentProtocolVersion == 7)
    #expect(decodedRequest == request)
    #expect(buildJSON["sshAgentIDs"] as? [String] == ["default"])
    #expect(!String(decoding: encodedRequest, as: UTF8.self).contains("SSH_AUTH_SOCK"))
    #expect(!String(decoding: encodedRequest, as: UTF8.self).contains("agent.sock"))
    #expect(buildJSON["outputKind"] as? String == "rootFilesystemDirectory")
    let remoteCacheJSON = try #require(buildJSON["remoteCache"] as? [String: Any])
    #expect(
      remoteCacheJSON["reference"] as? String
        == "registry.example/nativecontainers/cache:reviewed"
    )
    #expect(remoteCacheJSON["access"] as? String == "importAndExport")
    #expect(remoteCacheJSON["exportMode"] as? String == "max")
    #expect(!String(decoding: encodedRequest, as: UTF8.self).contains("type=registry"))
    #expect(buildJSON["cacheIn"] == nil)
    #expect(buildJSON["cacheOut"] == nil)
    #expect(buildJSON["destination"] == nil)
    #expect(buildJSON["destinationPath"] == nil)

    let artifacts = [
      ContainerBuildWorkerArtifact(
        kind: .ociArchive,
        path: "/private/artifacts/out.tar",
        sha256: String(repeating: "c", count: 64),
        byteCount: 42,
        entryCount: nil
      ),
      ContainerBuildWorkerArtifact(
        kind: .rootFilesystemArchive,
        path: "/private/artifacts/rootfs.tar",
        sha256: String(repeating: "d", count: 64),
        byteCount: 84,
        entryCount: nil
      ),
      ContainerBuildWorkerArtifact(
        kind: .rootFilesystemDirectory,
        path: "/private/artifacts/rootfs",
        sha256: String(repeating: "e", count: 64),
        byteCount: 126,
        entryCount: 7
      ),
    ]

    for artifact in artifacts {
      let result = ContainerBuildWorkerResult(
        buildID: buildID,
        artifact: artifact,
        stagingReference: nil,
        platforms: [.current],
        durationMilliseconds: 500,
        cacheReceipt: ContainerBuildWorkerCacheReceipt(
          mode: .appOwnedLocalV1,
          handoffToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
          fingerprintSHA256: String(repeating: "a", count: 64),
          byteCount: 1_024,
          entryCount: 12
        )
      )
      let event = ContainerBuildWorkerEvent.completed(result)
      let encodedEvent = try JSONEncoder().encode(event)
      let decodedEvent = try JSONDecoder().decode(
        ContainerBuildWorkerEvent.self,
        from: encodedEvent
      )
      #expect(decodedEvent == event)
      let eventText = try #require(String(data: encodedEvent, encoding: .utf8))
      #expect(!eventText.contains("type=local"))
      #expect(!eventText.contains("/Users/"))
    }
  }

  @Test
  func exporterConfigurationsPinRootFilesystemLayouts() {
    let imageStore = ContainerBuildExporterConfiguration(outputKind: .imageStore)
    #expect(imageStore.type == "oci")
    #expect(imageStore.additionalFields.isEmpty)

    let ociArchive = ContainerBuildExporterConfiguration(outputKind: .ociArchive)
    #expect(ociArchive.type == "oci")
    #expect(ociArchive.additionalFields.isEmpty)

    let archive = ContainerBuildExporterConfiguration(
      outputKind: .rootFilesystemArchive
    )
    #expect(archive.type == "tar")
    #expect(archive.additionalFields.isEmpty)
    #expect(archive.rawValue == "type=tar")

    let directory = ContainerBuildExporterConfiguration(
      outputKind: .rootFilesystemDirectory
    )
    #expect(directory.type == "local")
    #expect(directory.additionalFields == ["platform-split": "false"])
    #expect(directory.rawValue == "type=local,platform-split=false")
  }

  @Test
  func rejectsZeroAndOversizedFramesFromTheirHeaders() throws {
    var zeroDecoder = ContainerBuildWorkerFrameDecoder<FrameFixture>()
    #expect(throws: ContainerBuildWorkerFrameError.emptyFrame) {
      _ = try zeroDecoder.append(Data([0, 0, 0, 0]))
    }

    let oversized = UInt32(ContainerBuildWorkerFrameCodec.maximumPayloadBytes + 1)
    let header = Data([
      UInt8((oversized >> 24) & 0xFF),
      UInt8((oversized >> 16) & 0xFF),
      UInt8((oversized >> 8) & 0xFF),
      UInt8(oversized & 0xFF),
    ])
    var oversizedDecoder = ContainerBuildWorkerFrameDecoder<FrameFixture>()
    #expect(
      throws: ContainerBuildWorkerFrameError.frameTooLarge(
        actualBytes: Int(oversized),
        maximumBytes: ContainerBuildWorkerFrameCodec.maximumPayloadBytes
      )
    ) {
      _ = try oversizedDecoder.append(header)
    }
  }

  @Test
  func reportsTruncatedHeaderAndPayloadDeterministically() throws {
    var headerDecoder = ContainerBuildWorkerFrameDecoder<FrameFixture>()
    _ = try headerDecoder.append(Data([0, 0, 0]))
    #expect(throws: ContainerBuildWorkerFrameError.truncatedHeader(receivedBytes: 3)) {
      try headerDecoder.finish()
    }

    var payloadDecoder = ContainerBuildWorkerFrameDecoder<FrameFixture>()
    _ = try payloadDecoder.append(Data([0, 0, 0, 5, 0x7B, 0x7D]))
    #expect(
      throws: ContainerBuildWorkerFrameError.truncatedPayload(
        expectedBytes: 5,
        receivedBytes: 2
      )
    ) {
      try payloadDecoder.finish()
    }
  }

  @Test
  func rejectsEmptyAndOversizedEncodedPayloads() {
    #expect(throws: ContainerBuildWorkerFrameError.emptyFrame) {
      _ = try ContainerBuildWorkerFrameCodec.encodePayload(Data())
    }
    #expect(
      throws: ContainerBuildWorkerFrameError.frameTooLarge(
        actualBytes: ContainerBuildWorkerFrameCodec.maximumPayloadBytes + 1,
        maximumBytes: ContainerBuildWorkerFrameCodec.maximumPayloadBytes
      )
    ) {
      _ = try ContainerBuildWorkerFrameCodec.encodePayload(
        Data(count: ContainerBuildWorkerFrameCodec.maximumPayloadBytes + 1)
      )
    }
  }

  @Test
  func framedInputReturnsAShortPipeFrameWithoutWaitingForEOF() async throws {
    let pipe = Pipe()
    let expected = FrameFixture(id: 7, text: "short request")
    let frame = try ContainerBuildWorkerFrameCodec.encode(expected)
    try pipe.fileHandleForWriting.write(contentsOf: frame)

    let writeHandle = pipe.fileHandleForWriting
    let delayedClose = Task.detached { () -> Bool in
      do {
        try await Task.sleep(for: .milliseconds(1_500))
      } catch {
        return false
      }
      try? writeHandle.close()
      return true
    }
    let started = ContinuousClock.now
    let decoded = try await Task.detached {
      try ContainerBuildWorkerFramedInput.readOne(
        from: pipe.fileHandleForReading.fileDescriptor,
        as: FrameFixture.self
      )
    }.value
    let elapsed = started.duration(to: .now)

    delayedClose.cancel()
    let delayedCloseRan = await delayedClose.value
    if !delayedCloseRan {
      try? writeHandle.close()
    }
    try? pipe.fileHandleForReading.close()

    #expect(decoded == expected)
    #expect(elapsed < .milliseconds(750))
  }
}

@Suite(.serialized)
struct ContainerBuildWorkerProcessTests {
  @Test
  func pathBoundaryAcceptsChildOfDirectoryURLWithTrailingSeparator() {
    let parent = URL(fileURLWithPath: "/tmp/native-build/context", isDirectory: true)
    let child = URL(fileURLWithPath: "/tmp/native-build/context/Dockerfile")

    #expect(ContainerBuildPathBoundary.contains(child, within: parent))
  }

  @Test
  func pathBoundaryRejectsSiblingWithSharedTextualPrefix() {
    let parent = URL(fileURLWithPath: "/tmp/native-build/context", isDirectory: true)
    let sibling = URL(fileURLWithPath: "/tmp/native-build/context-copy/Dockerfile")

    #expect(!ContainerBuildPathBoundary.contains(sibling, within: parent))
  }

  @Test
  func pathBoundaryRejectsTheContextDirectoryItself() {
    let parent = URL(fileURLWithPath: "/tmp/native-build/context", isDirectory: true)
    let samePath = URL(fileURLWithPath: "/tmp/native-build/context")

    #expect(!ContainerBuildPathBoundary.contains(samePath, within: parent))
  }

  @Test
  func drainsHighVolumeStandardErrorAndDeliversFramedEvents() async throws {
    let request = makeStartBuilderRequest()
    let hello = ContainerBuildWorkerEvent.hello()
    let progress = ContainerBuildWorkerEvent.progress(
      .preparingBuilder,
      message: "Preparing native builder"
    )
    let terminal = ContainerBuildWorkerEvent.builderReady(message: "Ready")
    let process = try makeFixtureProcess(
      events: [progress, terminal],
      commandsBeforeEvents: [
        "/usr/bin/yes native-build-diagnostic | /usr/bin/head -c 1500000 >&2"
      ]
    )
    let recorder = BuildWorkerEventRecorder()

    let output = try await process.run(request) { event in
      await recorder.record(event)
    }

    let recordedEvents = await recorder.events
    #expect(recordedEvents == [hello, progress, terminal])
    #expect(output.events == recordedEvents)
    #expect(output.terminalEvent == terminal)
    #expect(output.result == nil)
    #expect(output.exitStatus == 0)
    #expect(output.standardErrorWasTruncated)
    #expect(output.standardErrorTail.utf8.count <= 1_024 * 1_024)
    #expect(output.standardErrorTail.hasSuffix("diagnostic\n"))
  }

  @Test
  func streamsShortProgressFrameBeforeWorkerExit() async throws {
    let hello = try ContainerBuildWorkerFrameCodec.encode(
      ContainerBuildWorkerEvent.hello()
    )
    let progress = try ContainerBuildWorkerFrameCodec.encode(
      ContainerBuildWorkerEvent.progress(.building, message: "BuildKit started")
    )
    let terminal = try ContainerBuildWorkerFrameCodec.encode(
      ContainerBuildWorkerEvent.builderReady(message: "Ready")
    )
    let printFrame: (Data) -> String = {
      "printf '%s' '\($0.base64EncodedString())' | /usr/bin/base64 -D"
    }
    let process = ContainerBuildWorkerProcess(
      executableLocator: FixedContainerBuildWorkerExecutableLocator(
        executableURL: URL(filePath: "/bin/sh")
      ),
      arguments: [
        "-c",
        [
          printFrame(hello),
          printFrame(progress),
          "/bin/sleep 1.5",
          printFrame(terminal),
          "exit 0",
        ].joined(separator: "\n"),
      ],
      environmentSource: [:]
    )
    let recorder = BuildWorkerEventRecorder()
    let task = Task {
      try await process.run(makeStartBuilderRequest()) { event in
        await recorder.record(event)
      }
    }

    let started = ContinuousClock.now
    var sawProgress = false
    for _ in 0..<15 {
      if await recorder.events.contains(where: { $0.phase == .building }) {
        sawProgress = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let progressDelay = started.duration(to: .now)
    #expect(sawProgress)
    #expect(progressDelay < .seconds(1))

    let output = try await task.value
    #expect(output.terminalEvent.kind == .builderReady)
  }

  @Test
  func requiresExactlyOneCompatibleHelloAsTheFirstEvent() async throws {
    let ready = ContainerBuildWorkerEvent.builderReady(message: "Ready")
    let missingHello = try makeFixtureProcess(events: [ready], includesHello: false)
    await expectProcessError(.missingHello, from: missingHello)

    let incompatibleHello = try makeFixtureProcess(
      events: [.hello(protocolVersion: ContainerBuildWorkerRequest.currentProtocolVersion + 1)],
      includesHello: false
    )
    await expectProcessError(
      .incompatibleProtocolVersion(
        received: ContainerBuildWorkerRequest.currentProtocolVersion + 1,
        expected: ContainerBuildWorkerRequest.currentProtocolVersion
      ),
      from: incompatibleHello
    )

    let duplicateHello = try makeFixtureProcess(events: [.hello(), ready])
    await expectProcessError(.duplicateHello, from: duplicateHello)
  }

  @Test
  func rejectsMissingTerminalEvent() async throws {
    let process = try makeFixtureProcess(
      events: [.progress(.validating, message: "Only progress")]
    )

    do {
      _ = try await process.run(makeStartBuilderRequest())
      Issue.record("Expected a missing-terminal-event failure.")
    } catch let error as ContainerBuildWorkerProcessError {
      guard case .missingTerminalEvent(let status, _) = error else {
        Issue.record("Unexpected process error: \(error)")
        return
      }
      #expect(status == 0)
    }
  }

  @Test
  func rejectsDuplicateTerminalEvents() async throws {
    let terminal = ContainerBuildWorkerEvent.builderReady(message: "Ready")
    let process = try makeFixtureProcess(events: [terminal, terminal])

    do {
      _ = try await process.run(makeStartBuilderRequest())
      Issue.record("Expected a duplicate-terminal-event failure.")
    } catch let error as ContainerBuildWorkerProcessError {
      guard case .duplicateTerminalEvent(let first, let duplicate) = error else {
        Issue.record("Unexpected process error: \(error)")
        return
      }
      #expect(first == .builderReady)
      #expect(duplicate == .builderReady)
    }
  }

  @Test
  func rejectsNonzeroExitAfterSuccessEvent() async throws {
    let process = try makeFixtureProcess(
      events: [.builderReady(message: "Ready")],
      exitStatus: 7
    )

    do {
      _ = try await process.run(makeStartBuilderRequest())
      Issue.record("Expected a nonzero-exit failure.")
    } catch let error as ContainerBuildWorkerProcessError {
      guard case .nonzeroExit(let status, _) = error else {
        Issue.record("Unexpected process error: \(error)")
        return
      }
      #expect(status == 7)
    }
  }

  @Test
  func preservesWorkerFailureAndPartialImageDigest() async throws {
    let failure = ContainerBuildWorkerFailure(
      code: "partial-import",
      message: "Tag finalization failed",
      buildID: UUID(),
      partialImageDigest: "sha256:partial"
    )
    let process = try makeFixtureProcess(
      events: [.failed(failure)],
      exitStatus: 1
    )

    do {
      _ = try await process.run(makeStartBuilderRequest())
      Issue.record("Expected a worker failure.")
    } catch let error as ContainerBuildWorkerProcessError {
      guard case .workerFailed(let reportedFailure, let status, _) = error else {
        Issue.record("Unexpected process error: \(error)")
        return
      }
      #expect(reportedFailure == failure)
      #expect(reportedFailure.partialImageDigest == "sha256:partial")
      #expect(status == 1)
    }
  }

  @Test
  func secretBuildDrainsAndSuppressesWorkerDiagnostics() async throws {
    let sentinel = "super-secret-worker-sentinel"
    let sentinelData = Data(sentinel.utf8)
    let payload = try ContainerBuildSecretSourcePayload(entries: [
      ProcessTestSecretStreamingEntry(id: "token", data: sentinelData)
    ])
    let request = makeSecretBuildRequestForProcessTests(secretIDs: payload.ids)
    let failure = ContainerBuildWorkerFailure(
      code: "build-failed",
      message: "Build output exposed \(sentinel)",
      buildID: request.build?.buildID,
      partialImageDigest: nil
    )
    let process = try makeFixtureProcess(
      events: [.failed(failure)],
      commandsBeforeEvents: ["printf '%s' '\(sentinel)' >&2"],
      exitStatus: 1
    )
    let recorder = BuildWorkerEventRecorder()

    do {
      _ = try await process.run(request, secrets: payload) { event in
        await recorder.record(event)
      }
      Issue.record("Expected a sanitized worker failure.")
    } catch let error as ContainerBuildWorkerProcessError {
      guard case .workerFailed(let sanitized, _, let tail) = error else {
        Issue.record("Unexpected process error: \(error)")
        return
      }
      #expect(sanitized.message == ContainerBuildWorkerDiagnostics.suppressedMessage)
      #expect(tail == ContainerBuildWorkerDiagnostics.suppressedMessage)
      #expect(!sanitized.message.contains(sentinel))
      #expect(!sanitized.message.contains(sentinelData.base64EncodedString()))
    }

    let events = await recorder.events
    #expect(events.last?.message == ContainerBuildWorkerDiagnostics.suppressedMessage)
    #expect(
      events.last?.failure?.message
        == ContainerBuildWorkerDiagnostics.suppressedMessage)
  }

  @Test
  func cancellationEscalatesPastIgnoredTerminateSignal() async throws {
    let process = try makeFixtureProcess(
      events: [],
      commandsBeforeEvents: ["trap '' TERM", "while :; do :; done"],
      terminationGracePeriod: .milliseconds(100)
    )
    let task = Task {
      try await process.run(makeStartBuilderRequest())
    }

    try await Task.sleep(for: .milliseconds(100))
    let started = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, got \(error).")
    }
    #expect(started.duration(to: .now) < .seconds(2))
  }

  @Test
  func environmentIsAllowlistedAndDropsCredentialChannels() {
    let environment = ContainerBuildWorkerEnvironment.sanitized(from: [
      "PATH": "/custom/bin",
      "HOME": "/Users/test",
      "TMPDIR": "/tmp/test",
      "CONTAINER_APP_ROOT": "/runtime/app",
      "CONTAINER_INSTALL_ROOT": "/runtime/install",
      "CONTAINER_DEFAULT_PLATFORM": "linux/arm64",
      "CONTAINER_REGISTRY_USER": "secret-user",
      "CONTAINER_REGISTRY_TOKEN": "secret-token",
      "DOCKER_CONFIG": "/secret/docker",
      "MY_PASSWORD": "secret-password",
      "SSH_AUTH_SOCK": "/secret/agent.sock",
    ])

    #expect(environment["PATH"] == "/custom/bin")
    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["TMPDIR"] == "/tmp/test")
    #expect(environment["CONTAINER_APP_ROOT"] == "/runtime/app")
    #expect(environment["CONTAINER_INSTALL_ROOT"] == "/runtime/install")
    #expect(environment["CONTAINER_DEFAULT_PLATFORM"] == "linux/arm64")
    #expect(environment["CONTAINER_REGISTRY_USER"] == nil)
    #expect(environment["CONTAINER_REGISTRY_TOKEN"] == nil)
    #expect(environment["DOCKER_CONFIG"] == nil)
    #expect(environment["MY_PASSWORD"] == nil)
    #expect(environment["SSH_AUTH_SOCK"] == nil)
  }

  @Test
  func sshSocketIsInjectedOnlyForReviewedOptIn() async throws {
    let socketPath = "/tmp/nativecontainers-reviewed-agent.sock"
    let optedIn = try makeFixtureProcess(
      events: [.builderReady(message: "ready")],
      commandsBeforeEvents: [
        "test \"$SSH_AUTH_SOCK\" = '\(socketPath)' || exit 12"
      ],
      environmentSource: ["SSH_AUTH_SOCK": socketPath]
    )
    let optedInOutput = try await optedIn.run(makeStartBuilderRequest(forwardsSSHAgent: true))
    #expect(optedInOutput.diagnostics == .suppressed)

    let optedOut = try makeFixtureProcess(
      events: [.builderReady(message: "ready")],
      commandsBeforeEvents: [
        "test -z \"${SSH_AUTH_SOCK+x}\" || exit 13"
      ],
      environmentSource: ["SSH_AUTH_SOCK": socketPath]
    )
    let optedOutOutput = try await optedOut.run(makeStartBuilderRequest())
    #expect(optedOutOutput.diagnostics == .captured(tail: "", wasTruncated: false))
  }

  @Test
  func reviewedSSHRequiresAnAvailableWorkerSocket() async throws {
    let process = try makeFixtureProcess(events: [.builderReady(message: "ready")])
    await expectProcessError(
      .sshAgentUnavailable,
      from: process,
      request: makeStartBuilderRequest(forwardsSSHAgent: true)
    )
  }

  @Test
  func locatorNeverFallsBackOutsideAnApplicationBundle() throws {
    let appLocator = DefaultContainerBuildWorkerExecutableLocator(
      bundleURL: URL(filePath: "/Applications/NativeContainers.app", directoryHint: .isDirectory),
      bundleExecutableURL: URL(filePath: "/tmp/debug/NativeContainers")
    )
    #expect(
      try appLocator.locateBuildWorker().path(percentEncoded: false)
        == "/Applications/NativeContainers.app/Contents/Helpers/NativeContainersBuildWorker"
    )

    let nestedBundleLocator = DefaultContainerBuildWorkerExecutableLocator(
      bundleURL: URL(
        filePath: "/Applications/NativeContainers.app/Contents/PlugIns/Tests.xctest",
        directoryHint: .isDirectory
      ),
      bundleExecutableURL: URL(filePath: "/tmp/debug/NativeContainersTests")
    )
    #expect(
      try nestedBundleLocator.locateBuildWorker().path(percentEncoded: false)
        == "/Applications/NativeContainers.app/Contents/Helpers/NativeContainersBuildWorker"
    )

    let debugLocator = DefaultContainerBuildWorkerExecutableLocator(
      bundleURL: URL(filePath: "/tmp/NativeContainersTests.xctest", directoryHint: .isDirectory),
      bundleExecutableURL: URL(filePath: "/tmp/debug/NativeContainersTests")
    )
    #expect(
      try debugLocator.locateBuildWorker().path(percentEncoded: false)
        == "/tmp/debug/NativeContainersBuildWorker"
    )
  }
}

private final class ProcessTestSecretStreamingEntry:
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

private struct FrameFixture: Codable, Equatable, Sendable {
  let id: Int
  let text: String
}

private actor BuildWorkerEventRecorder {
  private(set) var events: [ContainerBuildWorkerEvent] = []

  func record(_ event: ContainerBuildWorkerEvent) {
    events.append(event)
  }
}

private func makeStartBuilderRequest(
  forwardsSSHAgent: Bool = false
) -> ContainerBuildWorkerRequest {
  ContainerBuildWorkerRequest(
    operation: .startBuilder,
    builder: ContainerBuilderConfiguration(
      cpuCount: nil,
      memoryMiB: nil,
      forwardsSSHAgent: forwardsSSHAgent,
      allowsRecreateStoppedBuilder: false,
      allowsStopRunningBuilder: false
    )
  )
}

private func makeSecretBuildRequestForProcessTests(
  secretIDs: [String]
) -> ContainerBuildWorkerRequest {
  ContainerBuildWorkerRequest(
    operation: .build,
    build: ContainerBuildWorkerBuildRequest(
      buildID: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!,
      contextPath: "/tmp/nativecontainers-worker-process/context",
      dockerfilePath: "/tmp/nativecontainers-worker-process/context/Dockerfile",
      dockerfileSHA256: String(repeating: "a", count: 64),
      contextFingerprint: String(repeating: "b", count: 64),
      dockerignorePath: nil,
      dockerignoreSHA256: nil,
      tags: [
        ContainerBuildTagExpectation(
          reference: "nativecontainers.local/process-test:latest",
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

private func makeFixtureProcess(
  events: [ContainerBuildWorkerEvent],
  commandsBeforeEvents: [String] = [],
  exitStatus: Int32 = 0,
  terminationGracePeriod: Duration = .milliseconds(250),
  includesHello: Bool = true,
  environmentSource: [String: String] = [:]
) throws -> ContainerBuildWorkerProcess {
  var commands = commandsBeforeEvents
  let framedEvents = (includesHello ? [.hello()] : []) + events
  for event in framedEvents {
    let frame = try ContainerBuildWorkerFrameCodec.encode(event)
    commands.append(
      "printf '%s' '\(frame.base64EncodedString())' | /usr/bin/base64 -D"
    )
  }
  commands.append("exit \(exitStatus)")
  return ContainerBuildWorkerProcess(
    executableLocator: FixedContainerBuildWorkerExecutableLocator(
      executableURL: URL(filePath: "/bin/sh")
    ),
    arguments: ["-c", commands.joined(separator: "\n")],
    environmentSource: environmentSource,
    terminationGracePeriod: terminationGracePeriod
  )
}

private func expectProcessError(
  _ expected: ContainerBuildWorkerProcessError,
  from process: ContainerBuildWorkerProcess,
  request: ContainerBuildWorkerRequest = makeStartBuilderRequest(),
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  do {
    _ = try await process.run(request)
    Issue.record("Expected worker process error \(expected).", sourceLocation: sourceLocation)
  } catch let error as ContainerBuildWorkerProcessError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record("Expected \(expected), got \(error).", sourceLocation: sourceLocation)
  }
}
