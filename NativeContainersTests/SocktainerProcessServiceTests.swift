import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Socktainer process service")
struct SocktainerProcessServiceTests {
  private let executableURL = URL(filePath: "/tmp/socktainer")

  @Test
  func gracefulStopUsesExactOwnedSessionWithoutKill() async throws {
    let fixture = ProcessFixture(signalBehavior: .exitOnTerm)
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    try await service.stop()

    #expect(fixture.session.receivedSignals == [SIGTERM])
    #expect(fixture.socketInspector.removedIdentities == [fixture.identity])
    #expect(await service.status() == .stopped)
  }

  @Test
  func stopEscalatesFromTermToKillWhenGracefulExitStalls() async throws {
    let fixture = ProcessFixture(signalBehavior: .exitOnKill)
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    try await service.stop()

    #expect(fixture.session.receivedSignals == [SIGTERM, SIGKILL])
    #expect(await service.status() == .stopped)
  }

  @Test
  func forceStopIsAnImmediateKillPoint() async throws {
    let fixture = ProcessFixture(signalBehavior: .exitOnKill)
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    try await service.forceStop()

    #expect(fixture.session.receivedSignals == [SIGKILL])
    #expect(await service.status() == .stopped)
  }

  @Test
  func foreignSocketFailsClosedBeforeProcessLaunch() async {
    let fixture = ProcessFixture(
      signalBehavior: .exitOnKill,
      socketStates: [.socket(ProcessFixture.identity)]
    )
    let service = fixture.makeService()

    await #expect(throws: DockerCompatibilityError.foreignSocket(fixture.socketURL)) {
      try await service.start(executableURL: executableURL)
    }

    #expect(fixture.launcher.launchCount == 0)
    #expect(await service.status() == .blockedByForeignSocket(fixture.socketURL))
  }

  @Test
  func startupTimeoutAutomaticallyEscalatesToKill() async {
    let fixture = ProcessFixture(
      signalBehavior: .exitOnKill,
      socketStates: [.absent]
    )
    let service = fixture.makeService(startupTimeout: .milliseconds(2))

    await #expect(throws: DockerCompatibilityError.processStartupTimedOut) {
      try await service.start(executableURL: executableURL)
    }

    #expect(fixture.session.receivedSignals == [SIGTERM, SIGKILL])
  }

  @Test
  func disappearingOwnedSocketAutomaticallyStopsBridge() async throws {
    let fixture = ProcessFixture(signalBehavior: .exitOnTerm)
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    fixture.socketInspector.setStates([.absent])

    let state = await service.status()

    guard case .failed(let message) = state else {
      Issue.record("Expected a failed state after the owned socket disappeared.")
      return
    }
    #expect(message.contains("disappeared"))
    #expect(fixture.session.receivedSignals == [SIGTERM])
  }

  @Test
  func unexpectedExitIsReportedInsteadOfClaimingStopped() async throws {
    let fixture = ProcessFixture(signalBehavior: .exitOnKill)
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    fixture.session.exit(status: 17, standardError: "bridge failed")

    let state = await service.status()

    guard case .failed(let message) = state else {
      Issue.record("Expected an unexpected-exit failure.")
      return
    }
    #expect(message.contains("17"))
    #expect(message.contains("bridge failed"))
  }

  @Test
  func pingReadinessRequiresOKAndPinnedDockerAPIVersion() {
    let valid = Data(
      "HTTP/1.1 200 OK\r\nApi-Version: 1.51\r\nContent-Length: 2\r\n\r\nOK".utf8
    )
    let wrongVersion = Data(
      "HTTP/1.1 200 OK\r\nApi-Version: 1.52\r\nContent-Length: 2\r\n\r\nOK".utf8
    )
    let wrongBody = Data(
      "HTTP/1.1 200 OK\r\nApi-Version: 1.51\r\nContent-Length: 5\r\n\r\nNOPE".utf8
    )

    #expect(
      UnixSocketSocktainerReadinessProbe.isValidPingResponse(
        valid,
        expectedAPIVersion: "1.51"
      )
    )
    #expect(
      !UnixSocketSocktainerReadinessProbe.isValidPingResponse(
        wrongVersion,
        expectedAPIVersion: "1.51"
      )
    )
    #expect(
      !UnixSocketSocktainerReadinessProbe.isValidPingResponse(
        wrongBody,
        expectedAPIVersion: "1.51"
      )
    )
  }

  @Test
  func readinessRechecksSocketIdentityBeforeClaimingOwnership() async throws {
    let first = SocktainerSocketIdentity(device: 1, inode: 10, owner: 501)
    let rebound = SocktainerSocketIdentity(device: 1, inode: 11, owner: 501)
    let fixture = ProcessFixture(
      signalBehavior: .exitOnKill,
      socketStates: [
        .absent,
        .socket(first),
        .socket(rebound),
        .socket(rebound),
        .socket(rebound),
      ]
    )
    let service = fixture.makeService()

    try await service.start(executableURL: executableURL)
    try await service.forceStop()

    #expect(fixture.socketInspector.removedIdentities == [rebound])
  }

  @Test
  func terminationSentinelSynchronouslyRemovesOnlyCapturedSocketIdentity() {
    let identity = SocktainerSocketIdentity(device: 3, inode: 99, owner: 501)
    let inspector = MockSocktainerSocketInspector(states: [.socket(identity)])
    let sentinel = SocktainerTerminationSentinel(socketInspector: inspector)

    sentinel.set(identity: identity)
    sentinel.cleanup()
    sentinel.cleanup()

    #expect(inspector.removedIdentities == [identity])
  }
}

private final class ProcessFixture: @unchecked Sendable {
  static let identity = SocktainerSocketIdentity(device: 1, inode: 2, owner: 501)

  let socketURL = URL(filePath: "/tmp/nativecontainers-tests/container.sock")
  let identity = ProcessFixture.identity
  let session: MockHostProcessSession
  let launcher: MockHostProcessLauncher
  let socketInspector: MockSocktainerSocketInspector

  init(
    signalBehavior: MockHostProcessSession.SignalBehavior,
    socketStates: [SocktainerSocketState]? = nil
  ) {
    session = MockHostProcessSession(signalBehavior: signalBehavior)
    launcher = MockHostProcessLauncher(session: session)
    socketInspector = MockSocktainerSocketInspector(
      states: socketStates ?? [.absent, .socket(Self.identity)]
    )
  }

  func makeService(
    startupTimeout: Duration = .milliseconds(100)
  ) -> SocktainerProcessService {
    SocktainerProcessService(
      socketURL: socketURL,
      launcher: launcher,
      socketInspector: socketInspector,
      readinessProbe: StaticSocktainerReadinessProbe(isReady: true),
      startupTimeout: startupTimeout,
      gracefulStopTimeout: .milliseconds(2),
      killConfirmationTimeout: .milliseconds(10),
      pollInterval: .milliseconds(1)
    )
  }
}

private struct StaticSocktainerReadinessProbe: SocktainerReadinessProbing {
  let isReady: Bool

  func isReady(socketURL: URL) async -> Bool {
    isReady
  }
}

private final class MockHostProcessLauncher: HostProcessLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let session: MockHostProcessSession
  private var storedLaunchCount = 0

  var launchCount: Int {
    lock.withLock { storedLaunchCount }
  }

  init(session: MockHostProcessSession) {
    self.session = session
  }

  func launch(_ configuration: HostProcessConfiguration) throws -> any HostProcessSession {
    lock.withLock {
      storedLaunchCount += 1
    }
    return session
  }
}

private final class MockHostProcessSession: HostProcessSession, @unchecked Sendable {
  enum SignalBehavior {
    case exitOnTerm
    case exitOnKill
    case neverExit
  }

  private struct State {
    var isRunning = true
    var terminationStatus: Int32?
    var signals: [Int32] = []
    var output = HostProcessOutput(
      standardOutput: "",
      standardError: "",
      wasTruncated: false
    )
  }

  private let lock = NSLock()
  private let signalBehavior: SignalBehavior
  private var state = State()

  let processID: Int32 = 4242

  var isRunning: Bool {
    lock.withLock { state.isRunning }
  }

  var terminationStatus: Int32? {
    lock.withLock { state.terminationStatus }
  }

  var receivedSignals: [Int32] {
    lock.withLock { state.signals }
  }

  init(signalBehavior: SignalBehavior) {
    self.signalBehavior = signalBehavior
  }

  func send(signal: Int32) throws {
    lock.withLock {
      state.signals.append(signal)
      let shouldExit =
        (signal == SIGTERM && signalBehavior == .exitOnTerm)
        || (signal == SIGKILL && signalBehavior != .neverExit)
      if shouldExit {
        state.isRunning = false
        state.terminationStatus = 0
      }
    }
  }

  func capturedOutput() -> HostProcessOutput {
    lock.withLock { state.output }
  }

  func exit(
    status: Int32,
    standardOutput: String = "",
    standardError: String = ""
  ) {
    lock.withLock {
      state.isRunning = false
      state.terminationStatus = status
      state.output = HostProcessOutput(
        standardOutput: standardOutput,
        standardError: standardError,
        wasTruncated: false
      )
    }
  }
}

private final class MockSocktainerSocketInspector:
  SocktainerSocketInspecting, @unchecked Sendable
{
  private let lock = NSLock()
  private var states: [SocktainerSocketState]
  private var removed: [SocktainerSocketIdentity] = []

  var removedIdentities: [SocktainerSocketIdentity] {
    lock.withLock { removed }
  }

  init(states: [SocktainerSocketState]) {
    self.states = states
  }

  func prepareSocketDirectory() throws {}

  func inspectSocket() throws -> SocktainerSocketState {
    lock.withLock {
      guard let first = states.first else { return .absent }
      if states.count > 1 {
        states.removeFirst()
      }
      return first
    }
  }

  func removeSocket(ifMatching identity: SocktainerSocketIdentity) throws {
    lock.withLock {
      removed.append(identity)
      if states == [.socket(identity)] {
        states = [.absent]
      }
    }
  }

  func setStates(_ states: [SocktainerSocketState]) {
    lock.withLock {
      self.states = states
    }
  }
}
