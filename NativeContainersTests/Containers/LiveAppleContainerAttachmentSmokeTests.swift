import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Live container attachments", .serialized)
struct LiveAppleContainerAttachmentSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func mountsReviewedHostDirectoryReadOnlyAcrossRestart() async throws {
    let service = AppleContainerService()
    let suffix = UUID().uuidString.lowercased()
    let containerID = "nativecontainers-host-\(suffix.prefix(8))"
    let rootURL = URL(
      filePath: "/private/tmp/nativecontainers-host-\(suffix)",
      directoryHint: .isDirectory
    )
    let sourceURL = rootURL.appending(path: "Source", directoryHint: .isDirectory)
    let markerURL = sourceURL.appending(path: "marker.txt", directoryHint: .notDirectory)
    let blockedURL = sourceURL.appending(path: "blocked.txt", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try Data("host-directory-ok\n".utf8).write(to: markerURL)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let reviewed = try service.reviewHostDirectory(
      ContainerHostDirectoryReviewRequest(
        sourceURL: sourceURL,
        containerPath: "/workspace/source",
        isReadOnly: true
      )
    )
    let attachments = try ContainerAttachmentSelection(
      volumeMounts: [],
      hostDirectoryMounts: [reviewed],
      networks: [],
      publishedSockets: [],
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

    do {
      try await service.createContainer(request: request) { _ in }
      let snapshot = try await AppleContainerSnapshotReader().get(id: containerID)
      let hostMounts = snapshot.configuration.mounts.filter(\.isVirtiofs)
      #expect(hostMounts.count == 1)
      let mount = try #require(hostMounts.first)
      #expect(mount.source == reviewed.lastKnownPath)
      #expect(mount.destination == "/workspace/source")
      #expect(mount.options == ["ro"])

      try await service.startContainer(id: containerID)
      try await expectHostMarker(in: containerID, service: service)
      let writeResult = try await service.executeCommand(
        in: containerID,
        request: ContainerCommandRequest(
          executable: "/bin/touch",
          arguments: ["/workspace/source/blocked.txt"]
        )
      )
      #expect(writeResult.exitCode != 0)
      #expect(!FileManager.default.fileExists(atPath: blockedURL.nativeContainersPOSIXPath))

      try await restart(containerID, service: service)
      try await expectHostMarker(in: containerID, service: service)
      try await deleteRunningContainer(containerID, service: service)
    } catch {
      await cleanUpContainer(containerID, service: service)
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func forwardsReviewedSSHAgentAcrossRestart() async throws {
    let socketPath = "/private/tmp/nativecontainers-agent-\(UUID().uuidString.lowercased()).sock"
    let agentSocket = try LiveSSHAgentSocket(path: socketPath)
    let sshAgentService = AppleContainerSSHAgentService(
      environmentProvider: { ["SSH_AUTH_SOCK": agentSocket.path] }
    )
    let reviewedAgent = try #require(sshAgentService.availability().configuration)
    let service = AppleContainerService(sshAgentService: sshAgentService)
    let containerID = "nativecontainers-ssh-\(UUID().uuidString.lowercased().prefix(8))"
    let request = try ContainerCreationRequest(
      name: containerID,
      imageReference: "docker.io/library/alpine:3.21",
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/sh", "-c", "sleep 60"],
      startAfterCreation: false,
      sshAgent: reviewedAgent
    )

    do {
      try await service.createContainer(request: request) { _ in }
      let snapshot = try await AppleContainerSnapshotReader().get(id: containerID)
      #expect(snapshot.configuration.ssh)

      try await service.startContainer(id: containerID)
      try await expectForwardedSSHAgent(in: containerID, service: service)
      try await restart(containerID, service: service)
      try await expectForwardedSSHAgent(in: containerID, service: service)
      try await deleteRunningContainer(containerID, service: service)
    } catch {
      await cleanUpContainer(containerID, service: service)
      throw error
    }
  }

  private func expectForwardedSSHAgent(
    in containerID: String,
    service: AppleContainerService
  ) async throws {
    let result = try await service.executeCommand(
      in: containerID,
      request: ContainerCommandRequest(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf '%s\\n' \"$SSH_AUTH_SOCK\"; test -S \"$SSH_AUTH_SOCK\"",
        ]
      )
    )
    #expect(result.exitCode == 0)
    #expect(
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        == "/var/host-services/ssh-auth.sock")
  }

  private func expectHostMarker(
    in containerID: String,
    service: AppleContainerService
  ) async throws {
    let result = try await service.executeCommand(
      in: containerID,
      request: ContainerCommandRequest(
        executable: "/bin/cat",
        arguments: ["/workspace/source/marker.txt"]
      )
    )
    #expect(result.exitCode == 0)
    #expect(
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        == "host-directory-ok")
  }

  private func restart(
    _ containerID: String,
    service: AppleContainerService
  ) async throws {
    try await service.forceStopContainer(id: containerID)
    try await waitForStoppedContainer(id: containerID, service: service)
    try await service.startContainer(id: containerID)
  }

  private func deleteRunningContainer(
    _ containerID: String,
    service: AppleContainerService
  ) async throws {
    try await service.forceStopContainer(id: containerID)
    try await waitForStoppedContainer(id: containerID, service: service)
    try await service.deleteContainer(id: containerID)
    let remains = try await service.loadInventory().containers.contains { $0.id == containerID }
    #expect(!remains)
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
      if state != .running { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw LiveContainerAttachmentSmokeError.timedOut("container \(id) to stop")
  }

  private func cleanUpContainer(
    _ containerID: String,
    service: AppleContainerService
  ) async {
    try? await service.forceStopContainer(id: containerID)
    for _ in 0..<40 {
      if (try? await service.loadInventory().containers.first { $0.id == containerID }?.state)
        != .running
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    try? await service.deleteContainer(id: containerID)
  }
}

private final class LiveSSHAgentSocket: @unchecked Sendable {
  let path: String

  private let descriptor: Int32

  init(path: String) throws {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw LiveContainerAttachmentSmokeError.posix(operation: "create socket", code: errno)
    }

    let pathBytes = Array(path.utf8CString)
    var address = sockaddr_un()
    let maximumPathBytes = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maximumPathBytes else {
      Darwin.close(descriptor)
      throw LiveContainerAttachmentSmokeError.socketPathTooLong
    }

    _ = Darwin.unlink(path)
    address.sun_family = sa_family_t(AF_UNIX)
    let addressLength = socklen_t(
      MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathBytes.count
    )
    address.sun_len = UInt8(addressLength)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: maximumPathBytes) { destination in
        pathBytes.withUnsafeBufferPointer { source in
          destination.initialize(from: source.baseAddress!, count: pathBytes.count)
        }
      }
    }

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bound == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw LiveContainerAttachmentSmokeError.posix(operation: "bind socket", code: code)
    }
    guard Darwin.listen(descriptor, 4) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      _ = Darwin.unlink(path)
      throw LiveContainerAttachmentSmokeError.posix(operation: "listen on socket", code: code)
    }

    self.path = path
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
    _ = Darwin.unlink(path)
  }
}

private enum LiveContainerAttachmentSmokeError: LocalizedError {
  case posix(operation: String, code: Int32)
  case socketPathTooLong
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .posix(let operation, let code):
      "Could not \(operation) (errno \(code))."
    case .socketPathTooLong:
      "The disposable SSH-agent socket path is too long."
    case .timedOut(let operation):
      "Timed out waiting for \(operation)."
    }
  }
}
