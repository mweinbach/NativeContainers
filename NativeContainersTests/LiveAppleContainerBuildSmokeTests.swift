import ContainerAPIClient
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
    secrets: [ImageBuildSecretSelection]
  ) -> ImageBuildRequest {
    ImageBuildRequest(
      contextDirectory: contextURL,
      dockerfile: nil,
      secrets: secrets,
      tags: [tag],
      platforms: [.current],
      buildArguments: [],
      labels: ["com.nativecontainers.smoke=true"],
      targetStage: "",
      noCache: true,
      pullLatest: true,
      builderCPUCount: nil,
      builderMemoryMiB: nil
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

private enum LiveBuildSmokeError: LocalizedError {
  case timedOutWaitingForBuild

  var errorDescription: String? {
    "Timed out waiting for the embedded worker to enter BuildKit."
  }
}
