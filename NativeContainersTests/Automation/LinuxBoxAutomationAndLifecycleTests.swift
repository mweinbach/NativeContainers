import Darwin
import XCTest
@testable import NativeContainers

@MainActor
final class LinuxBoxAutomationAndLifecycleTests: XCTestCase {
  func testStatusBypassesExecBusyAndStopPreemptsExec() async throws {
    let runtime = AutomationRuntimeDouble()
    let service = LinuxBoxAutomationService(runtime: runtime)
    let id = UUID()
    let execRequest = try NativeContainersControlRequest(
      operation: .exec,
      timeoutSeconds: 30,
      payload: .exec(
        LinuxBoxExecPayload(
          id: CanonicalUUID(id),
          argv: ["/usr/bin/sleep", "10"]
        )
      )
    )
    let execTask = Task { @MainActor in
      try await service.execute(execRequest)
    }
    while !runtime.execStarted {
      try await Task.sleep(for: .milliseconds(10))
    }

    let status = try await service.execute(
      NativeContainersControlRequest(
        operation: .status,
        timeoutSeconds: 30,
        payload: .id(LinuxBoxIDPayload(id: CanonicalUUID(id)))
      )
    )
    let statusEnvelope = try JSONDecoder().decode(
      NativeContainersControlResponse<LinuxBoxSummary>.self,
      from: status
    )
    XCTAssertTrue(statusEnvelope.ok)

    do {
      _ = try await service.execute(
        NativeContainersControlRequest(
          operation: .verify,
          timeoutSeconds: 30,
          payload: .id(LinuxBoxIDPayload(id: CanonicalUUID(id)))
        )
      )
      XCTFail("verify must reject overlap with exec")
    } catch let error as NativeContainersAutomationError {
      XCTAssertEqual(error.code, .busy)
    }

    let stopped = try await service.execute(
      NativeContainersControlRequest(
        operation: .stop,
        timeoutSeconds: 30,
        payload: .id(LinuxBoxIDPayload(id: CanonicalUUID(id)))
      )
    )
    XCTAssertTrue(runtime.stopCalled)
    XCTAssertTrue(runtime.execCancelled)
    XCTAssertFalse(runtime.stopStartedBeforeExecCancellation)
    XCTAssertTrue(
      try JSONDecoder().decode(
        NativeContainersControlResponse<LinuxBoxChangedResult>.self,
        from: stopped
      ).ok
    )
    do {
      _ = try await execTask.value
      XCTFail("preempted exec must not complete successfully")
    } catch let error as NativeContainersAutomationError {
      XCTAssertEqual(error, .disconnected)
    }
  }
  func testStatusPreservesResidentialDescriptorProfile() async throws {
    let runtime = AutomationRuntimeDouble()
    runtime.profile = .residential
    let service = LinuxBoxAutomationService(runtime: runtime)
    let id = UUID()
    let request = try NativeContainersControlRequest(
      operation: .status,
      timeoutSeconds: 30,
      payload: .id(LinuxBoxIDPayload(id: CanonicalUUID(id)))
    )
    let response = try await service.execute(request)
    let envelope = try JSONDecoder().decode(
      NativeContainersControlResponse<LinuxBoxSummary>.self,
      from: response
    )
    try envelope.validate(expectedRequestID: request.requestID)
    XCTAssertTrue(envelope.ok)
    XCTAssertEqual(envelope.data?.profile, .residential)
  }

  func testControlServerSecuresSocketAndStopsActiveClients() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root
      .appending(path: "Control", directoryHint: .isDirectory)
      .appending(path: "control-v1.sock")
    let runtime = AutomationRuntimeDouble()
    let service = LinuxBoxAutomationService(runtime: runtime)
    let server = NativeContainersControlServer(
      socketURL: socketURL,
      automation: service
    )
    try server.start()
    defer { server.stop() }

    var socketStat = Darwin.stat()
    XCTAssertEqual(Darwin.lstat(socketURL.path, &socketStat), 0)
    XCTAssertEqual(socketStat.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(mode_t(socketStat.st_mode & 0o7777), 0o600)
    XCTAssertEqual(socketStat.st_uid, getuid())

    let request = try NativeContainersControlRequest(
      operation: .doctor,
      timeoutSeconds: 30,
      payload: .empty
    )
    let response = try await Self.roundTrip(request, socketURL: socketURL)
    let envelope = try JSONDecoder().decode(
      NativeContainersControlResponse<LinuxBoxDoctorResult>.self,
      from: response
    )
    try envelope.validate(expectedRequestID: request.requestID)

    let client = try await Self.connect(to: socketURL)
    server.stop()
    let closed = await Task.detached {
      var byte: UInt8 = 0
      return Darwin.recv(client, &byte, 1, 0)
    }.value
    Darwin.close(client)
    XCTAssertEqual(closed, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
  }

  func testControlServerRejectsExtraInputAndCancelsExec() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root
      .appending(path: "Control", directoryHint: .isDirectory)
      .appending(path: "control-v1.sock")
    let runtime = AutomationRuntimeDouble()
    let server = NativeContainersControlServer(
      socketURL: socketURL,
      automation: LinuxBoxAutomationService(runtime: runtime)
    )
    try server.start()
    defer { server.stop() }

    let id = UUID()
    let request = try NativeContainersControlRequest(
      operation: .exec,
      timeoutSeconds: 30,
      payload: .exec(
        LinuxBoxExecPayload(
          id: CanonicalUUID(id),
          argv: ["/usr/bin/sleep", "10"]
        )
      )
    )
    let client = try await Self.connect(to: socketURL)
    defer { Darwin.close(client) }
    try BoundedJSONFrameCodec.write(
      BoundedJSONFrameCodec.encode(request),
      to: client
    )
    while !runtime.execStarted {
      try await Task.sleep(for: .milliseconds(10))
    }
    var extra: UInt8 = 0x7b
    XCTAssertEqual(Darwin.send(client, &extra, 1, 0), 1)

    let closed = await Task.detached {
      var byte: UInt8 = 0
      return Darwin.recv(client, &byte, 1, 0)
    }.value
    XCTAssertEqual(closed, 0)
    while !runtime.execCancelled {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testLifecycleForceStopsOnlyFailedExactGenerations() async throws {
    let first = NativeContainersLinuxRuntimeGeneration(id: UUID(), generation: UUID())
    let second = NativeContainersLinuxRuntimeGeneration(id: UUID(), generation: UUID())
    let server = ControlServerDouble()
    let runtime = LifecycleRuntimeDouble(
      generations: [first, second],
      gracefulFailures: [second]
    )
    let coordinator = NativeContainersApplicationLifecycleCoordinator(
      server: server,
      runtime: runtime
    )

    let terminated = await coordinator.terminateApplication()
    let gracefulCalls = await runtime.gracefulCalls
    let forceCalls = await runtime.forceCalls
    XCTAssertTrue(terminated)
    XCTAssertEqual(server.events, ["stop-mutations", "stop"])
    XCTAssertEqual(Set(gracefulCalls), Set([first, second]))
    XCTAssertEqual(forceCalls, [second])
  }

  private func temporaryDirectory() -> URL {
    URL(
      fileURLWithPath: "/tmp/nc-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
  }

  private nonisolated static func roundTrip(
    _ request: NativeContainersControlRequest,
    socketURL: URL
  ) async throws -> Data {
    try await Task.detached {
      let descriptor = try connectSynchronously(to: socketURL)
      defer { Darwin.close(descriptor) }
      let requestFrame = try BoundedJSONFrameCodec.encode(request)
      try BoundedJSONFrameCodec.write(requestFrame, to: descriptor)
      let response = try BoundedJSONFrameCodec.readPayload(from: descriptor)
      var extra: UInt8 = 0
      XCTAssertEqual(Darwin.recv(descriptor, &extra, 1, 0), 0)
      return response
    }.value
  }

  private nonisolated static func connect(to socketURL: URL) async throws -> Int32 {
    try await Task.detached {
      try connectSynchronously(to: socketURL)
    }.value
  }
}

@MainActor
private final class AutomationRuntimeDouble: LinuxBoxAutomationRuntime, @unchecked Sendable {
  var execStarted = false
  var stopCalled = false
  var execCancelled = false
  var stopStartedBeforeExecCancellation = false
  var profile: LinuxBoxProfile = .standard

  func doctor() async throws -> LinuxBoxDoctorResult {
    LinuxBoxDoctorResult(checks: [])
  }

  func prepareImage() async throws -> LinuxBoxImagePrepareResult {
    LinuxBoxImagePrepareResult(
      imageID: "test-image",
      cached: true,
      compressedSHA256: String(repeating: "0", count: 64),
      rawSHA512: String(repeating: "0", count: 128)
    )
  }

  func list() async throws -> LinuxBoxListResult { LinuxBoxListResult(boxes: []) }

  func create(_ payload: LinuxBoxCreatePayload) async throws -> LinuxBoxChangedResult {
    LinuxBoxChangedResult(box: summary(id: UUID()), changed: true)
  }

  func status(id: UUID) async throws -> LinuxBoxSummary { summary(id: id) }

  func start(id: UUID) async throws -> LinuxBoxVerifiedResult {
    LinuxBoxVerifiedResult(box: summary(id: id), verification: verification())
  }

  func pause(id: UUID) async throws -> LinuxBoxChangedResult {
    LinuxBoxChangedResult(box: summary(id: id), changed: true)
  }

  func resume(id: UUID) async throws -> LinuxBoxChangedResult {
    LinuxBoxChangedResult(box: summary(id: id), changed: true)
  }

  func exec(
    id: UUID,
    argv: [String],
    deadline: ContinuousClock.Instant
  ) async throws -> LinuxBoxExecResult {
    execStarted = true
    do {
      while true {
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch is CancellationError {
      execCancelled = true
      throw CancellationError()
    }
  }

  func verify(id: UUID) async throws -> LinuxBoxVerifiedResult {
    LinuxBoxVerifiedResult(box: summary(id: id), verification: verification())
  }

  func refresh(id: UUID) async throws -> LinuxBoxVerifiedResult {
    LinuxBoxVerifiedResult(box: summary(id: id), verification: verification())
  }

  func stop(id: UUID) async throws -> LinuxBoxChangedResult {
    stopStartedBeforeExecCancellation = !execCancelled
    stopCalled = true
    return LinuxBoxChangedResult(box: summary(id: id), changed: true)
  }

  func destroy(id: UUID) async throws -> LinuxBoxDestroyResult {
    LinuxBoxDestroyResult(id: CanonicalUUID(id), state: "absent", changed: true)
  }

  func smoke(name: String, profile: LinuxBoxProfile) async throws -> LinuxBoxSmokeResult {
    LinuxBoxSmokeResult(
      id: CanonicalUUID(UUID()),
      state: "absent",
      verification: verification(),
      cleanup: []
    )
  }

  private func summary(id: UUID) -> LinuxBoxSummary {
    LinuxBoxSummary(
      id: CanonicalUUID(id),
      name: "test",
      state: .running,
      ready: true,
      imageID: "test-image",
      agentProtocol: 2,
      cpuCount: 4,
      memoryBytes: 8 * 1_073_741_824,
      diskBytes: 32 * 1_073_741_824,
      profile: profile
    )
  }

  private func verification() -> LinuxBoxVerification {
    LinuxBoxVerification(
      verifiedAt: Date(timeIntervalSince1970: 0),
      egress: .init(
        hostDirectIP: "192.0.2.1",
        hostProxyIP: "192.0.2.2",
        curlIP: "192.0.2.2",
        chromiumIP: "192.0.2.2",
        isp: "test",
        country: "US"
      ),
      doh: .init(address: "1.1.1.1", serverName: "cloudflare-dns.com"),
      checks: []
    )
  }
}

@MainActor
private final class ControlServerDouble: NativeContainersControlServing, @unchecked Sendable {
  var events: [String] = []
  func start() throws {}
  func stopAcceptingMutations() { events.append("stop-mutations") }
  func stop() { events.append("stop") }
}

private actor LifecycleRuntimeDouble: NativeContainersLinuxRuntimeLifecycle {
  let generations: [NativeContainersLinuxRuntimeGeneration]
  let gracefulFailures: Set<NativeContainersLinuxRuntimeGeneration>
  var gracefulCalls: [NativeContainersLinuxRuntimeGeneration] = []
  var forceCalls: [NativeContainersLinuxRuntimeGeneration] = []

  init(
    generations: [NativeContainersLinuxRuntimeGeneration],
    gracefulFailures: Set<NativeContainersLinuxRuntimeGeneration>
  ) {
    self.generations = generations
    self.gracefulFailures = gracefulFailures
  }

  func reconcileLaunchOwnership() async throws {}

  func activeGenerations() async throws -> [NativeContainersLinuxRuntimeGeneration] {
    generations
  }

  func quiesceAndStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    gracefulCalls.append(generation)
    return !gracefulFailures.contains(generation)
  }

  func forceStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    forceCalls.append(generation)
    return true
  }
}

private func connectSynchronously(to socketURL: URL) throws -> Int32 {
  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  do {
    guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = Array(socketURL.path.utf8)
    guard bytes.count + 1 <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
      throw POSIXError(.ENAMETOOLONG)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { destination[index] = byte }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  } catch {
    Darwin.close(descriptor)
    throw error
  }
}
