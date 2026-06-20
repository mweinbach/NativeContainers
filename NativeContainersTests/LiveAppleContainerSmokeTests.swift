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
      try await service.pullImage(reference: source) { _ in }
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
