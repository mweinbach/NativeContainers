import ContainerAPIClient
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleContainerBuildSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_BUILD_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_TESTS=1 with Apple container services running."
    )
  )
  func embeddedWorkerBuildsImportsRunsAndCleansImage() async throws {
    let fixture = try LiveBuildFixture(prefix: "native-build-smoke")
    defer { fixture.removeContext() }
    let buildService = AppleContainerBuildService()
    let containerService = AppleContainerService()
    let plan = try await buildService.prepareBuild(fixture.request) { _ in }

    do {
      let result = try await buildService.build(
        plan,
        authorization: ImageBuildAuthorization(
          allowsTagReplacement: false,
          allowsRecreateStoppedBuilder: true,
          allowsStopRunningBuilder: false
        )
      ) { _ in }
      #expect(result.tags == [plan.tags[0].reference])
      #expect(result.platforms == [.current])

      let inspection = try await containerService.inspectImage(reference: plan.tags[0].reference)
      #expect(inspection.digest == result.imageDigest)
      #expect(inspection.variants.contains { $0.architecture == "arm64" })

      try await containerService.createContainer(
        request: try ContainerCreationRequest(
          name: fixture.containerID,
          imageReference: plan.tags[0].reference,
          cpuCount: 1,
          memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
          arguments: ["/bin/sh", "-c", "while :; do sleep 3600; done"],
          startAfterCreation: true
        )
      ) { _ in }
      let command = try await containerService.executeCommand(
        in: fixture.containerID,
        request: try ContainerCommandRequest(
          executable: "/bin/cat",
          arguments: ["/nativecontainers-marker"]
        )
      )
      #expect(command.exitCode == 0)
      #expect(command.standardOutput == "native-build-ok\n")

      await cleanUpContainer(fixture.containerID, service: containerService)
      await cleanUpImage(plan.tags[0].reference, service: containerService)
      let remains = try await containerService.loadInventory().images.contains {
        $0.reference == plan.tags[0].reference
      }
      #expect(!remains)
      try await expectArtifactsRemoved(buildID: plan.id)
    } catch {
      await buildService.discardBuild(plan)
      await cleanUpContainer(fixture.containerID, service: containerService)
      await cleanUpImage(plan.tags[0].reference, service: containerService)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_BUILD_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_TESTS=1 with Apple container services running."
    )
  )
  func secretBuildConsumesMountWithoutRetainingPrintedValue() async throws {
    let sentinel = Data("nativecontainers-live-secret-sentinel".utf8)
    let fixture = try LiveBuildFixture(
      prefix: "native-build-secret",
      runInstruction: """
        RUN --mount=type=secret,id=token sh -c 'test "$(cat /run/secrets/token)" = "nativecontainers-live-secret-sentinel" && cat /run/secrets/token >&2 && printf "secret-ok\\n" > /nativecontainers-secret-marker'
        RUN test ! -e /run/secrets/token
        """
    )
    let secretURL = fixture.contextURL.deletingLastPathComponent().appending(
      path: "\(fixture.contextURL.lastPathComponent)-token.secret",
      directoryHint: .notDirectory
    )
    try sentinel.write(to: secretURL)
    #expect(Darwin.chmod(secretURL.path(percentEncoded: false), 0o600) == 0)
    defer {
      fixture.removeContext()
      try? FileManager.default.removeItem(at: secretURL)
    }

    let buildService = AppleContainerBuildService()
    let containerService = AppleContainerService()
    let textProbe = LiveBuildTextProbe()
    let plan = try await buildService.prepareBuild(
      fixture.request(
        secrets: [ImageBuildSecretSelection(id: "token", sourceURL: secretURL)]
      )
    ) { progress in
      await textProbe.record(progress)
    }

    do {
      let result = try await buildService.build(
        plan,
        authorization: ImageBuildAuthorization(
          allowsTagReplacement: false,
          allowsRecreateStoppedBuilder: true,
          allowsStopRunningBuilder: false
        )
      ) { progress in
        await textProbe.record(progress)
      }
      #expect(
        result.logTail == ContainerBuildWorkerDiagnostics.suppressedMessage
      )
      let retained = await textProbe.text + "\n" + result.logTail
      #expect(!retained.contains("nativecontainers-live-secret-sentinel"))
      #expect(!retained.contains(sentinel.base64EncodedString()))

      try await containerService.createContainer(
        request: try ContainerCreationRequest(
          name: fixture.containerID,
          imageReference: plan.tags[0].reference,
          cpuCount: 1,
          memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
          arguments: ["/bin/sh", "-c", "while :; do sleep 3600; done"],
          startAfterCreation: true
        )
      ) { _ in }
      let marker = try await containerService.executeCommand(
        in: fixture.containerID,
        request: try ContainerCommandRequest(
          executable: "/bin/cat",
          arguments: ["/nativecontainers-secret-marker"]
        )
      )
      #expect(marker.standardOutput == "secret-ok\n")
      let absent = try await containerService.executeCommand(
        in: fixture.containerID,
        request: try ContainerCommandRequest(
          executable: "/bin/sh",
          arguments: ["-c", "test ! -e /run/secrets/token"]
        )
      )
      #expect(absent.exitCode == 0)

      await cleanUpContainer(fixture.containerID, service: containerService)
      await cleanUpImage(plan.tags[0].reference, service: containerService)
      try await expectArtifactsRemoved(buildID: plan.id)
    } catch {
      await buildService.discardBuild(plan)
      await cleanUpContainer(fixture.containerID, service: containerService)
      await cleanUpImage(plan.tags[0].reference, service: containerService)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_BUILD_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_TESTS=1 with Apple container services running."
    )
  )
  func ociArchivePublishesWithoutImageStoreMutation() async throws {
    try await withBuiltOutput(
      prefix: "native-build-oci",
      kind: .ociArchive,
      destinationName: "image.oci.tar"
    ) { destination, completion in
      guard case .ociArchive(let committed, let sha256, let byteCount) = completion else {
        Issue.record("Expected an OCI archive completion")
        return
      }
      #expect(committed == destination.standardizedFileURL)
      let data = try Data(contentsOf: destination)
      #expect(byteCount == Int64(data.count))
      #expect(sha256 == sha256Hex(data))

      let entries = try await tarEntries(at: destination)
      #expect(entries.contains { $0.hasSuffix("oci-layout") })
      #expect(entries.contains { $0.hasSuffix("index.json") })
      #expect(entries.contains { $0.contains("blobs/sha256/") })
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_BUILD_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_TESTS=1 with Apple container services running."
    )
  )
  func rootFilesystemTarPublishesReadableMarker() async throws {
    try await withBuiltOutput(
      prefix: "native-build-rootfs-tar",
      kind: .rootFilesystemArchive,
      destinationName: "rootfs.tar"
    ) { destination, completion in
      guard
        case .rootFilesystemArchive(let committed, let sha256, let byteCount) =
          completion
      else {
        Issue.record("Expected a root filesystem archive completion")
        return
      }
      #expect(committed == destination.standardizedFileURL)
      let data = try Data(contentsOf: destination)
      #expect(byteCount == Int64(data.count))
      #expect(sha256 == sha256Hex(data))

      let entries = try await tarEntries(at: destination)
      let marker = try #require(
        entries.first { $0 == "linux_arm64/nativecontainers-marker" }
      )
      let markerContents = try await tarContents(at: destination, member: marker)
      #expect(markerContents == "native-build-ok\n")
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_BUILD_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_TESTS=1 with Apple container services running."
    )
  )
  func rootFilesystemFolderPublishesReadableMarker() async throws {
    try await withBuiltOutput(
      prefix: "native-build-rootfs-folder",
      kind: .rootFilesystemDirectory,
      destinationName: "rootfs"
    ) { destination, completion in
      guard
        case .rootFilesystemDirectory(let committed, let byteCount, let entryCount) =
          completion
      else {
        Issue.record("Expected a root filesystem directory completion")
        return
      }
      #expect(committed == destination.standardizedFileURL)
      #expect(byteCount > 0)
      #expect(entryCount > 0)
      let marker = destination.appending(
        path: "nativecontainers-marker",
        directoryHint: .notDirectory
      )
      let markerContents = try String(contentsOf: marker, encoding: .utf8)
      #expect(markerContents == "native-build-ok\n")
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_DESTRUCTIVE_LIVE_BUILD_CACHE_TESTS"
      ] == "1",
      "Set NATIVECONTAINERS_DESTRUCTIVE_LIVE_BUILD_CACHE_TESTS=1 to replace the persistent app-owned cache."
    )
  )
  func appOwnedLocalCacheExportsValidGenerationsAndResets() async throws {
    let token = UUID().uuidString.lowercased()
    let fixture = try LiveBuildFixture(
      prefix: "native-build-cache",
      runInstruction: "RUN sleep 8 && echo \(token) > /nativecontainers-marker"
    )
    let outputRoot = try makeOutputRoot(prefix: "native-build-cache")
    let cacheService = AppleAppOwnedBuildCacheService()
    defer {
      fixture.removeContext()
      try? FileManager.default.removeItem(at: outputRoot)
    }

    try await cacheService.resetCache()
    do {
      let first = try await runCachedBuild(
        fixture: fixture,
        destination: outputRoot.appending(
          path: "first.oci.tar",
          directoryHint: .notDirectory
        )
      )
      let loadedFirstCache = try await cacheService.loadCache()
      let firstCache = try #require(loadedFirstCache)
      #expect(firstCache.byteCount > 0)
      #expect(firstCache.entryCount > 0)
      #expect(first.duration > .seconds(6))

      let second = try await runCachedBuild(
        fixture: fixture,
        destination: outputRoot.appending(
          path: "second.oci.tar",
          directoryHint: .notDirectory
        )
      )
      let loadedSecondCache = try await cacheService.loadCache()
      let secondCache = try #require(loadedSecondCache)
      #expect(secondCache.byteCount > 0)
      #expect(secondCache.entryCount > 0)
      #expect(second.progressMessages.contains { $0.contains("Updated app-owned cache") })
    } catch {
      try? await cacheService.resetCache()
      throw error
    }

    try await cacheService.resetCache()
    #expect(try await cacheService.loadCache() == nil)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_BUILD_CANCELLATION_TESTS"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_CANCELLATION_TESTS=1 for the destructive cancellation smoke."
    )
  )
  func cancellingEmbeddedWorkerLeavesNoFinalTag() async throws {
    let fixture = try LiveBuildFixture(
      prefix: "native-build-cancel",
      runInstruction: "RUN sleep 60"
    )
    defer { fixture.removeContext() }
    let buildService = AppleContainerBuildService()
    let containerService = AppleContainerService()
    let phaseProbe = LiveBuildPhaseProbe()
    let plan = try await buildService.prepareBuild(fixture.request) { _ in }
    let task = Task {
      try await buildService.build(
        plan,
        authorization: ImageBuildAuthorization(
          allowsTagReplacement: false,
          allowsRecreateStoppedBuilder: true,
          allowsStopRunningBuilder: false
        )
      ) { progress in
        await phaseProbe.record(progress.phase)
      }
    }

    do {
      try await waitForBuilding(phaseProbe)
      task.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await task.value
      }
      let exists = try await containerService.loadInventory().images.contains {
        $0.reference == plan.tags[0].reference
      }
      #expect(!exists)
      try await expectArtifactsRemoved(buildID: plan.id)
    } catch {
      task.cancel()
      _ = try? await task.value
      await buildService.discardBuild(plan)
      await cleanUpImage(plan.tags[0].reference, service: containerService)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_BUILD_CANCELLATION_TESTS"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_BUILD_CANCELLATION_TESTS=1 for the destructive cancellation smoke."
    )
  )
  func cancellingAlternateOutputLeavesNoDestinationOrArtifacts() async throws {
    let fixture = try LiveBuildFixture(
      prefix: "native-build-output-cancel",
      runInstruction: "RUN sleep 60"
    )
    let outputRoot = try makeOutputRoot(prefix: "native-build-output-cancel")
    defer {
      fixture.removeContext()
      try? FileManager.default.removeItem(at: outputRoot)
    }
    let destination = outputRoot.appending(
      path: "cancelled-rootfs",
      directoryHint: .isDirectory
    )
    let buildService = AppleContainerBuildService()
    let phaseProbe = LiveBuildPhaseProbe()
    let plan = try await buildService.prepareBuild(
      fixture.request(
        output: ImageBuildOutputSelection(
          kind: .rootFilesystemDirectory,
          destinationURL: destination
        )
      )
    ) { _ in }
    let task = Task {
      try await buildService.build(
        plan,
        authorization: liveBuildAuthorization
      ) { progress in
        await phaseProbe.record(progress.phase)
      }
    }

    do {
      try await waitForBuilding(phaseProbe)
      task.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await task.value
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(
        try FileManager.default.contentsOfDirectory(
          at: outputRoot,
          includingPropertiesForKeys: nil
        ).isEmpty
      )
      try await expectArtifactsRemoved(buildID: plan.id)
    } catch {
      task.cancel()
      _ = try? await task.value
      await buildService.discardBuild(plan)
      throw error
    }
  }

  private var liveBuildAuthorization: ImageBuildAuthorization {
    ImageBuildAuthorization(
      allowsTagReplacement: false,
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: false
    )
  }

  private func withBuiltOutput(
    prefix: String,
    kind: ImageBuildOutputKind,
    destinationName: String,
    verify: (URL, ImageBuildCompletion) async throws -> Void
  ) async throws {
    let fixture = try LiveBuildFixture(prefix: prefix)
    let outputRoot = try makeOutputRoot(prefix: prefix)
    defer {
      fixture.removeContext()
      try? FileManager.default.removeItem(at: outputRoot)
    }
    let destination = outputRoot.appending(
      path: destinationName,
      directoryHint: kind == .rootFilesystemDirectory ? .isDirectory : .notDirectory
    )
    let buildService = AppleContainerBuildService()
    let containerService = AppleContainerService()
    let plan = try await buildService.prepareBuild(
      fixture.request(
        output: ImageBuildOutputSelection(
          kind: kind,
          destinationURL: destination
        )
      )
    ) { _ in }

    do {
      let result = try await buildService.build(
        plan,
        authorization: liveBuildAuthorization
      ) { _ in }
      #expect(result.platforms == [.current])
      try await verify(destination, result.output)
      let storedTagExists = try await containerService.loadInventory().images.contains {
        $0.reference == fixture.tag
      }
      #expect(!storedTagExists)
      #expect(
        try FileManager.default.contentsOfDirectory(
          at: outputRoot,
          includingPropertiesForKeys: nil
        ).map(\.lastPathComponent) == [destinationName]
      )
      try await expectArtifactsRemoved(buildID: plan.id)
    } catch {
      await buildService.discardBuild(plan)
      throw error
    }
  }

  private func runCachedBuild(
    fixture: LiveBuildFixture,
    destination: URL
  ) async throws -> (duration: Duration, progressMessages: [String]) {
    let service = AppleContainerBuildService()
    let progress = LiveBuildProgressProbe()
    let plan = try await service.prepareBuild(
      fixture.request(
        output: ImageBuildOutputSelection(
          kind: .ociArchive,
          destinationURL: destination
        ),
        cachePolicy: .appOwnedLocalV1
      )
    ) { _ in }
    let start = ContinuousClock.now
    do {
      _ = try await service.build(
        plan,
        authorization: liveBuildAuthorization
      ) { update in
        await progress.record(update)
      }
      try await expectArtifactsRemoved(buildID: plan.id)
      let progressValues = await progress.values
      return (
        start.duration(to: .now),
        progressValues.map(\.message)
      )
    } catch {
      await service.discardBuild(plan)
      throw error
    }
  }

  private func makeOutputRoot(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-output-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    guard chmod(root.nativeContainersPOSIXPath, 0o700) == 0 else {
      throw LiveBuildSmokeError.outputRootUnavailable(root.path)
    }
    return root
  }

  private func tarEntries(at archiveURL: URL) async throws -> [String] {
    let result = try await executeTar(["-tf", archiveURL.nativeContainersPOSIXPath])
    return result.standardOutput.split(separator: "\n").map(String.init)
  }

  private func tarContents(at archiveURL: URL, member: String) async throws -> String {
    let result = try await executeTar([
      "-xOf", archiveURL.nativeContainersPOSIXPath, member,
    ])
    return result.standardOutput
  }

  private func executeTar(_ arguments: [String]) async throws -> HostCommandResult {
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys where key.hasPrefix("DYLD_") {
      environment.removeValue(forKey: key)
    }
    let result = try await FoundationHostCommandExecutor().execute(
      executableURL: URL(filePath: "/usr/bin/tar"),
      arguments: arguments,
      environment: environment,
      timeout: .seconds(20)
    )
    guard result.exitCode == 0 else {
      throw LiveBuildSmokeError.tarFailed(
        exitCode: result.exitCode,
        output: result.standardError
      )
    }
    return result
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func waitForBuilding(
    _ probe: LiveBuildPhaseProbe,
    timeout: Duration = .seconds(90)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await probe.sawBuilding { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw LiveBuildSmokeError.timedOutWaitingForBuild
  }

  private func cleanUpContainer(
    _ id: String,
    service: AppleContainerService
  ) async {
    try? await service.forceStopContainer(id: id)
    for _ in 0..<80 {
      if (try? await service.loadInventory().containers.first { $0.id == id }?.state)
        != .running
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    try? await service.deleteContainer(id: id)
  }

  private func cleanUpImage(
    _ reference: String,
    service: AppleContainerService
  ) async {
    guard let plan = try? await service.prepareImageDeletion(reference: reference) else { return }
    _ = try? await service.deleteImage(plan)
  }

  private func expectArtifactsRemoved(buildID: UUID) async throws {
    let privateArtifact = PrivateBuildArtifactStore().artifactURL(buildID: buildID)
    #expect(!FileManager.default.fileExists(atPath: privateArtifact.path(percentEncoded: false)))
    let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
    let sharedExport = health.appRoot
      .appending(path: "builder", directoryHint: .isDirectory)
      .appending(path: buildID.uuidString.lowercased(), directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: sharedExport.path(percentEncoded: false)))
  }
}

private struct LiveBuildFixture {
  let contextURL: URL
  let tag: String
  let containerID: String

  init(
    prefix: String,
    runInstruction: String = "RUN printf 'native-build-ok\\n' > /nativecontainers-marker"
  ) throws {
    let suffix = UUID().uuidString.lowercased()
    contextURL = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(suffix)",
      directoryHint: .isDirectory
    )
    tag = "nativecontainers.local/\(prefix):\(suffix)"
    containerID = "\(prefix)-\(suffix.prefix(8))"
    try FileManager.default.createDirectory(at: contextURL, withIntermediateDirectories: false)
    let dockerfile = """
      FROM docker.io/library/alpine:3.21
      \(runInstruction)
      """
    try Data(dockerfile.utf8).write(to: contextURL.appending(path: "Dockerfile"))
  }

  var request: ImageBuildRequest {
    request(secrets: [])
  }

  func request(
    secrets: [ImageBuildSecretSelection],
    output: ImageBuildOutputSelection = .imageStore,
    cachePolicy: ImageBuildCachePolicy = .disabled
  ) -> ImageBuildRequest {
    ImageBuildRequest(
      contextDirectory: contextURL,
      dockerfile: nil,
      secrets: secrets,
      tags: output.kind.isRootFilesystem ? [] : [tag],
      platforms: [.current],
      buildArguments: [],
      labels: ["com.nativecontainers.smoke=true"],
      targetStage: "",
      cachePolicy: cachePolicy,
      pullLatest: true,
      builderCPUCount: nil,
      builderMemoryMiB: nil,
      output: output
    )
  }

  func request(
    output: ImageBuildOutputSelection,
    cachePolicy: ImageBuildCachePolicy = .disabled
  ) -> ImageBuildRequest {
    request(
      secrets: [],
      output: output,
      cachePolicy: cachePolicy
    )
  }

  func removeContext() {
    try? FileManager.default.removeItem(at: contextURL)
  }
}

private actor LiveBuildTextProbe {
  private(set) var values: [String] = []

  var text: String { values.joined(separator: "\n") }

  func record(_ progress: ImageBuildProgress) {
    values.append(progress.message)
    values.append(progress.logTail)
  }
}

private actor LiveBuildPhaseProbe {
  private(set) var sawBuilding = false

  func record(_ phase: ImageBuildProgress.Phase) {
    if phase == .building { sawBuilding = true }
  }
}

private actor LiveBuildProgressProbe {
  private(set) var values: [ImageBuildProgress] = []

  func record(_ progress: ImageBuildProgress) {
    values.append(progress)
  }
}

private enum LiveBuildSmokeError: LocalizedError {
  case timedOutWaitingForBuild
  case outputRootUnavailable(String)
  case tarFailed(exitCode: Int32, output: String)

  var errorDescription: String? {
    switch self {
    case .timedOutWaitingForBuild:
      "Timed out waiting for the embedded worker to enter BuildKit."
    case .outputRootUnavailable(let path):
      "Could not create a private live-build output root at \(path)."
    case .tarFailed(let exitCode, let output):
      "tar exited with status \(exitCode). \(output)"
    }
  }
}
