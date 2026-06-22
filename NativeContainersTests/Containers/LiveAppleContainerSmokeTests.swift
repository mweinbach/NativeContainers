import CryptoKit
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
  func exportStoppedRootFilesystemAndCleanUp() async throws {
    let service = AppleContainerService()
    let suffix = UUID().uuidString.lowercased()
    let containerID = "nativecontainers-export-\(suffix.prefix(8))"
    let marker = "nativecontainers-export-ok-\(suffix)"
    let markerPath = "/nativecontainers-export-marker"
    let outputRoot = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-export-smoke-\(suffix)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: outputRoot,
      withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: outputRoot.nativeContainersPOSIXPath
    )
    defer { try? FileManager.default.removeItem(at: outputRoot) }

    let archiveURL = outputRoot.appending(
      path: "rootfs.tar",
      directoryHint: .notDirectory
    )
    let blockedArchiveURL = outputRoot.appending(
      path: "existing.tar",
      directoryHint: .notDirectory
    )
    let initialStagingEntries = try filesystemExportStagingEntries()
    let request = try ContainerCreationRequest(
      name: containerID,
      imageReference: "docker.io/library/alpine:3.21",
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: [
        "/bin/sh",
        "-c",
        "umask 077; printf '%s\\n' \"$1\" > \(markerPath)",
        "nativecontainers-export",
        marker,
      ],
      startAfterCreation: true
    )

    do {
      try await service.createContainer(request: request) { _ in }
      let stoppedContainer = try await waitForStoppedContainerRecord(
        id: containerID,
        service: service
      )
      let exportRequest = try ContainerFilesystemExportRequest(
        container: stoppedContainer,
        destinationURL: archiveURL
      )
      let receipt = try await service.exportFilesystem(exportRequest)

      #expect(receipt.target == ContainerTerminalTargetIdentity(container: stoppedContainer))
      #expect(receipt.destinationURL == archiveURL.standardizedFileURL)
      let archiveData = try Data(contentsOf: archiveURL)
      #expect(receipt.byteCount == Int64(archiveData.count))
      #expect(receipt.byteCount > 0)
      #expect(receipt.sha256 == sha256Hex(archiveData))
      let archiveAttributes = try FileManager.default.attributesOfItem(
        atPath: archiveURL.nativeContainersPOSIXPath
      )
      #expect((archiveAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

      let entries = try await tarEntries(at: archiveURL)
      let markerEntry = try #require(
        entries.first { normalizedArchiveMember($0) == String(markerPath.dropFirst()) }
      )
      #expect(try await tarContents(at: archiveURL, member: markerEntry) == "\(marker)\n")

      let stagingAfterSuccess = try filesystemExportStagingEntries()
      #expect(stagingAfterSuccess.isSubset(of: initialStagingEntries))
      let preservedContents = Data("preserve-existing-destination\n".utf8)
      try preservedContents.write(to: blockedArchiveURL, options: .withoutOverwriting)
      let blockedRequest = try ContainerFilesystemExportRequest(
        container: stoppedContainer,
        destinationURL: blockedArchiveURL
      )
      await #expect(
        throws: ContainerFilesystemExportError.destinationMustBeNew(
          blockedArchiveURL.nativeContainersPOSIXPath
        )
      ) {
        try await service.exportFilesystem(blockedRequest)
      }
      #expect(try Data(contentsOf: blockedArchiveURL) == preservedContents)
      #expect(try filesystemExportStagingEntries().isSubset(of: stagingAfterSuccess))
      let outputEntries = try FileManager.default.contentsOfDirectory(
        atPath: outputRoot.nativeContainersPOSIXPath
      )
      #expect(
        !outputEntries.contains {
          $0.hasPrefix(".nativecontainers-") && $0.hasSuffix(".partial")
        }
      )

      try await service.deleteContainer(id: containerID)
      let remains = try await service.loadInventory().containers.contains {
        $0.id == containerID
      }
      #expect(!remains)
    } catch {
      await cleanUpRunningContainer(id: containerID, service: service)
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
      arguments: ["/bin/sleep", "3600"],
      startAfterCreation: true
    )
    var session: (any ContainerTerminalSession)?
    var outputTask: Task<Void, Never>?

    do {
      try await service.createContainer(request: request) { _ in }
      let shell = try await service.discoverShell(in: id)
      #expect(shell == ContainerShell(executable: "/bin/ash", source: .fallback))
      let openedSession = try await service.openTerminal(
        in: id,
        request: ContainerTerminalRequest(
          program: .executable(shell.executable),
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

  private func waitForStoppedContainerRecord(
    id: String,
    service: AppleContainerService,
    timeout: Duration = .seconds(30)
  ) async throws -> ContainerRecord {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let container = try await service.loadInventory().containers.first(where: {
        $0.id == id
      }), container.state == .stopped {
        return container
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw LiveAttachmentSmokeError.timedOut("container \(id) to reach stopped state")
  }

  private func filesystemExportStagingEntries() throws -> Set<String> {
    let stagingRoot = AppleContainerFilesystemExportService.defaultStagingRootDirectory()
    guard FileManager.default.fileExists(atPath: stagingRoot.nativeContainersPOSIXPath) else {
      return []
    }
    return Set(
      try FileManager.default.contentsOfDirectory(atPath: stagingRoot.nativeContainersPOSIXPath)
        .filter { $0.hasPrefix(".nativecontainers-export-") }
    )
  }

  private func tarEntries(at archiveURL: URL) async throws -> [String] {
    let result = try await executeTar(["-tf", archiveURL.nativeContainersPOSIXPath])
    return result.standardOutput.split(separator: "\n").map(String.init)
  }

  private func tarContents(at archiveURL: URL, member: String) async throws -> String {
    try await executeTar([
      "-xOf", archiveURL.nativeContainersPOSIXPath, member,
    ]).standardOutput
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
      throw LiveFilesystemExportSmokeError.tarFailed(
        exitCode: result.exitCode,
        output: result.standardError
      )
    }
    return result
  }

  private func normalizedArchiveMember(_ member: String) -> String {
    var value = member
    while value.hasPrefix("./") {
      value.removeFirst(2)
    }
    while value.hasPrefix("/") {
      value.removeFirst()
    }
    return value
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private enum LiveFilesystemExportSmokeError: LocalizedError {
  case tarFailed(exitCode: Int32, output: String)

  var errorDescription: String? {
    switch self {
    case .tarFailed(let exitCode, let output):
      "tar exited with status \(exitCode): \(output)"
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
