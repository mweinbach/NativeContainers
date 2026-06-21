import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleContainerSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func createInspectAndDeleteStoppedContainer() async throws {
    let service = AppleContainerService()
    let id = "nativecontainers-smoke-\(UUID().uuidString.lowercased().prefix(8))"
    let request = try ContainerCreationRequest(
      name: id,
      imageReference: "docker.io/library/alpine:3.21",
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/true"],
      startAfterCreation: false
    )

    do {
      try await service.createContainer(request: request) { _ in }
      let created = try await service.loadInventory().containers.first { $0.id == id }
      #expect(created?.state == .stopped)
      #expect(created?.cpuCount == 1)
      #expect(created?.memoryBytes == 256 * ContainerCreationRequest.bytesPerMiB)
      try await service.deleteContainer(id: id)
      let remains = try await service.loadInventory().containers.contains { $0.id == id }
      #expect(!remains)
    } catch {
      try? await service.deleteContainer(id: id)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func createWithReviewedVolumeNetworkAndPublishedSocket() async throws {
    let service = AppleContainerService()
    let suffix = UUID().uuidString.lowercased().prefix(8)
    let containerID = "nativecontainers-attach-\(suffix)"
    let volumeName = "nativecontainers-volume-\(suffix)"
    let networkName = "nativecontainers-network-\(suffix)"
    let volumeRequest = try VolumeCreateRequest(
      name: volumeName,
      sizeBytes: 16 * VolumeCreateRequest.bytesPerMiB
    )
    let networkRequest = try NetworkCreateRequest(
      name: networkName,
      mode: .nat
    )

    do {
      let volume = try await service.createVolume(
        try await service.prepareVolumeCreation(volumeRequest)
      )
      let network = try await service.createNetwork(
        try await service.prepareNetworkCreation(networkRequest)
      )
      let attachments = try ContainerAttachmentSelection(
        volumeMounts: [
          try ContainerVolumeMount(
            volume: volume,
            containerPath: "/data",
            isReadOnly: false
          )
        ],
        networks: [ContainerNetworkAttachment(network: network)],
        publishedSockets: [
          try ContainerUnixSocketPublication(
            hostSocketName: "api.sock",
            containerPath: "/run/api.sock"
          )
        ],
        requiredHostAccess: nil
      )
      let request = try ContainerCreationRequest(
        name: containerID,
        imageReference: "docker.io/library/alpine:3.21",
        cpuCount: 1,
        memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
        arguments: ["/bin/sh", "-c", "sleep 60"],
        attachments: attachments,
        startAfterCreation: false
      )

      try await service.createContainer(request: request) { _ in }
      let snapshot = try await AppleContainerSnapshotReader().get(id: containerID)
      #expect(snapshot.configuration.mounts.map(\.volumeName) == [volumeName])
      #expect(snapshot.configuration.networks.map(\.network) == [networkName])
      let publishedSocket = try #require(snapshot.configuration.publishedSockets.first)
      let environment = await service.loadContainerAttachmentEnvironment()
      #expect(publishedSocket.hostPath.string.hasPrefix(environment.publishedSocketRootPath))

      try await service.startContainer(id: containerID)
      try await waitForHostSocket(atPath: publishedSocket.hostPath.string)
      try await service.forceStopContainer(id: containerID)
      try await waitForStoppedContainer(id: containerID, service: service)
      try await waitForMissingPath(publishedSocket.hostPath.string)
      try await service.deleteContainer(id: containerID)

      let operationDirectory = URL(
        filePath: environment.publishedSocketRootPath,
        directoryHint: .isDirectory
      ).appending(
        path: request.operationID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      #expect(
        !FileManager.default.fileExists(atPath: operationDirectory.path(percentEncoded: false)))
      try await deleteNetworkIfPresent(networkName, service: service)
      try await deleteVolumeIfPresent(volumeName, service: service)
    } catch {
      await cleanUpRunningContainer(id: containerID, service: service)
      try? await deleteNetworkIfPresent(networkName, service: service)
      try? await deleteVolumeIfPresent(volumeName, service: service)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func interactiveTerminalPreservesPTYSemantics() async throws {
    let service = AppleContainerService()
    let id = "nativecontainers-pty-\(UUID().uuidString.lowercased().prefix(8))"
    let terminalSize = try ContainerTerminalSize(columns: 91, rows: 33)
    let request = try ContainerCreationRequest(
      name: id,
      imageReference: "docker.io/library/alpine:3.21",
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/sh", "-c", "while :; do sleep 3600; done"],
      startAfterCreation: true
    )
    var session: (any ContainerTerminalSession)?
    var outputTask: Task<Void, Never>?

    do {
      try await service.createContainer(request: request) { _ in }
      let openedSession = try await service.openTerminal(
        in: id,
        request: ContainerTerminalRequest(
          executable: "/bin/sh",
          arguments: [
            "-c",
            """
            IFS= read -r value
            printf 'native-pty-ok\\n'
            stty size
            printf 'input:%s\\n' "$value"
            trap 'printf "interrupt-ok\\n"; exit 0' INT
            while :; do sleep 30; done
            """,
          ],
          initialSize: terminalSize
        )
      )
      session = openedSession
      outputTask = Task {
        for await _ in openedSession.output {}
      }

      try await openedSession.resize(to: terminalSize)
      try await openedSession.sendInput(Data("round-trip\n".utf8))
      try await waitForTerminalOutput(openedSession, stage: .input) {
        $0.contains("native-pty-ok") && $0.contains("33 91")
          && $0.contains("input:round-trip")
      }
      try await openedSession.sendInput(Data([0x03]))
      try await waitForTerminalOutput(openedSession, stage: .interrupt) {
        $0.contains("interrupt-ok")
      }

      #expect(try await openedSession.wait() == 0)
      await outputTask?.value
      await cleanUpRunningContainer(id: id, service: service)
    } catch {
      outputTask?.cancel()
      await session?.close()
      await cleanUpRunningContainer(id: id, service: service)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func tagInspectAndDeleteImageReference() async throws {
    let service = AppleContainerService()
    let source = "docker.io/library/alpine:3.21"
    let target = "nativecontainers-smoke-\(UUID().uuidString.lowercased().prefix(8)):latest"
    let containerID = "nativecontainers-image-use-\(UUID().uuidString.lowercased().prefix(8))"

    do {
      let pullPlan = try await service.prepareImagePull(
        reference: source,
        platform: .current,
        transport: .automatic,
        unpackAfterPull: true,
        maxConcurrentDownloads: 3
      )
      _ = try await service.pullImage(
        pullPlan,
        authorization: ImagePullAuthorization(
          allowsInsecureTransport: pullPlan.requiresInsecureConfirmation,
          allowsExistingReferenceReplacement: pullPlan.replacesExistingReference,
          allowsAllPlatforms: false
        )
      ) { _ in }
      let tagPlan = try await service.prepareImageTag(source: source, target: target)
      try await service.tagImage(tagPlan, replacingExisting: false)

      let inspection = try await service.inspectImage(reference: tagPlan.targetReference)
      #expect(inspection.digest == tagPlan.sourceDigest)
      #expect(!inspection.variants.isEmpty)
      #expect(inspection.usedByContainerIDs.isEmpty)

      let containerRequest = try ContainerCreationRequest(
        name: containerID,
        imageReference: tagPlan.targetReference,
        cpuCount: 1,
        memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
        startAfterCreation: false
      )
      try await service.createContainer(request: containerRequest) { _ in }
      let inUsePlan = try await service.prepareImageDeletion(
        reference: tagPlan.targetReference
      )
      #expect(inUsePlan.usedByContainerIDs == [containerID])
      await #expect(
        throws: ImageManagementError.imageInUse(
          reference: tagPlan.targetReference,
          containerIDs: [containerID]
        )
      ) {
        try await service.deleteImage(inUsePlan)
      }
      try await service.deleteContainer(id: containerID)

      let deletionPlan = try await service.prepareImageDeletion(
        reference: tagPlan.targetReference
      )
      let result = try await service.deleteImage(deletionPlan)
      #expect(result.removedReferences == [tagPlan.targetReference])
      #expect(result.failedReferences.isEmpty)
      let remains = try await service.loadInventory().images.contains {
        $0.reference == tagPlan.targetReference
      }
      #expect(!remains)
    } catch {
      await cleanUpRunningContainer(id: containerID, service: service)
      await cleanUpImageReference(target, service: service)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LOCAL_REGISTRY_REPOSITORY"]
        != nil,
      "Set NATIVECONTAINERS_LOCAL_REGISTRY_REPOSITORY to a repository in a disposable localhost registry."
    )
  )
  func pushAndPullDisposableLocalRegistry() async throws {
    guard
      let repository = ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LOCAL_REGISTRY_REPOSITORY"
      ]
    else { return }
    try requireLocalRegistry(repository)

    let service = AppleContainerService()
    let source = "docker.io/library/alpine:3.21"
    let target = "\(repository):nativecontainers-\(UUID().uuidString.lowercased())"

    do {
      let sourcePull = try await service.prepareImagePull(
        reference: source,
        platform: .current,
        transport: .https,
        unpackAfterPull: false,
        maxConcurrentDownloads: 3
      )
      let sourceResult = try await service.pullImage(
        sourcePull,
        authorization: ImagePullAuthorization(
          allowsInsecureTransport: false,
          allowsExistingReferenceReplacement: sourcePull.replacesExistingReference,
          allowsAllPlatforms: false
        )
      ) { _ in }

      let tagPlan = try await service.prepareImageTag(source: source, target: target)
      try await service.tagImage(tagPlan, replacingExisting: false)
      let pushPlan = try await service.prepareImagePush(
        reference: target,
        platform: .current,
        transport: .http
      )
      try await service.pushImage(
        pushPlan,
        authorization: ImagePushAuthorization(
          allowsInsecureTransport: true,
          confirmsRemoteTagReplacement: true
        )
      ) { _ in }

      await cleanUpImageReference(target, service: service)
      let roundTripPull = try await service.prepareImagePull(
        reference: target,
        platform: .current,
        transport: .http,
        unpackAfterPull: true,
        maxConcurrentDownloads: 3
      )
      let roundTrip = try await service.pullImage(
        roundTripPull,
        authorization: ImagePullAuthorization(
          allowsInsecureTransport: true,
          allowsExistingReferenceReplacement: false,
          allowsAllPlatforms: false
        )
      ) { _ in }

      #expect(roundTrip.digest == sourceResult.digest)
      #expect(roundTrip.unpacked)
      await cleanUpImageReference(target, service: service)
    } catch {
      await cleanUpImageReference(target, service: service)
      throw error
    }
  }

  private func waitForHostSocket(
    atPath path: String,
    timeout: Duration = .seconds(5)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      if attributes?[.type] as? FileAttributeType == .typeSocket {
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw LiveAttachmentSmokeError.timedOut("host socket at \(path)")
  }

  private func waitForMissingPath(
    _ path: String,
    timeout: Duration = .seconds(5)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if !FileManager.default.fileExists(atPath: path) {
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw LiveAttachmentSmokeError.timedOut("socket cleanup at \(path)")
  }

  private func waitForStoppedContainer(
    id: String,
    service: AppleContainerService,
    timeout: Duration = .seconds(5)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let state = try await service.loadInventory().containers.first { $0.id == id }?.state
      if state != .running {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw LiveAttachmentSmokeError.timedOut("container \(id) to stop")
  }

  private func deleteVolumeIfPresent(
    _ name: String,
    service: AppleContainerService
  ) async throws {
    let plan = try await service.prepareVolumeDeletion(name: name)
    try await service.deleteVolume(plan)
  }

  private func deleteNetworkIfPresent(
    _ id: String,
    service: AppleContainerService
  ) async throws {
    let plan = try await service.prepareNetworkDeletion(id: id)
    try await service.deleteNetwork(plan)
  }

  private func waitForTerminalOutput(
    _ session: any ContainerTerminalSession,
    stage: LiveTerminalSmokeStage,
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable (String) -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition(await session.snapshot().retainedText) { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    let snapshot = await session.snapshot()
    throw LiveTerminalSmokeError.timedOut(
      stage,
      "lifecycle=\(snapshot.lifecycle), output=\(String(reflecting: snapshot.retainedText))"
    )
  }

  private func cleanUpRunningContainer(
    id: String,
    service: AppleContainerService
  ) async {
    try? await service.forceStopContainer(id: id)
    for _ in 0..<40 {
      if (try? await service.loadInventory().containers.first { $0.id == id }?.state)
        != .running
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    try? await service.deleteContainer(id: id)
  }

  private func cleanUpImageReference(
    _ reference: String,
    service: AppleContainerService
  ) async {
    guard let plan = try? await service.prepareImageDeletion(reference: reference) else { return }
    _ = try? await service.deleteImage(plan)
  }

  private func requireLocalRegistry(_ repository: String) throws {
    guard let authority = repository.split(separator: "/", maxSplits: 1).first else {
      throw LocalRegistrySmokeError.invalidRepository(repository)
    }
    let authorityValue = String(authority).lowercased()
    guard
      authorityValue == "localhost" || authorityValue.hasPrefix("localhost:")
        || authorityValue == "127.0.0.1" || authorityValue.hasPrefix("127.0.0.1:")
        || authorityValue == "[::1]" || authorityValue.hasPrefix("[::1]:")
    else {
      throw LocalRegistrySmokeError.nonLocalRepository(repository)
    }
  }
}

private enum LiveAttachmentSmokeError: LocalizedError {
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .timedOut(let operation):
      "Timed out waiting for \(operation)."
    }
  }
}

private enum LiveTerminalSmokeStage: String {
  case input
  case interrupt
}

private enum LiveTerminalSmokeError: LocalizedError {
  case timedOut(LiveTerminalSmokeStage, String)

  var errorDescription: String? {
    switch self {
    case .timedOut(let stage, let details):
      "Timed out waiting for \(stage.rawValue) terminal output: \(details)"
    }
  }
}

private enum LocalRegistrySmokeError: LocalizedError {
  case invalidRepository(String)
  case nonLocalRepository(String)

  var errorDescription: String? {
    switch self {
    case .invalidRepository(let repository):
      "“\(repository)” is not a registry repository."
    case .nonLocalRepository(let repository):
      "Live push smoke tests are restricted to disposable localhost registries, not “\(repository)”."
    }
  }
}
