import Darwin
import Foundation

struct SocktainerSocketIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
}

enum SocktainerSocketState: Equatable, Sendable {
  case absent
  case socket(SocktainerSocketIdentity)
  case unsafe(String)
}

protocol SocktainerSocketInspecting: Sendable {
  func prepareSocketDirectory() throws
  func inspectSocket() throws -> SocktainerSocketState
  func removeSocket(ifMatching identity: SocktainerSocketIdentity) throws
}

protocol SocktainerReadinessProbing: Sendable {
  func isReady(socketURL: URL) async -> Bool
  func hasListener(socketURL: URL) async -> Bool
}

extension SocktainerReadinessProbing {
  func hasListener(socketURL: URL) async -> Bool {
    await isReady(socketURL: socketURL)
  }
}

protocol SocktainerProcessManaging: Sendable {
  var socketURL: URL { get }
  func status() async -> SocktainerRuntimeState
  func start(executableURL: URL) async throws
  func stop() async throws
  func forceStop() async throws
  func removeStaleSocket() async throws
}

actor SocktainerProcessService: SocktainerProcessManaging {
  nonisolated let socketURL: URL

  private let launcher: any HostProcessLaunching
  private let socketInspector: any SocktainerSocketInspecting
  private let readinessProbe: any SocktainerReadinessProbing
  private let terminationSentinel: SocktainerTerminationSentinel
  private let environment: [String: String]?
  private let startupTimeout: Duration
  private let gracefulStopTimeout: Duration
  private let killConfirmationTimeout: Duration
  private let pollInterval: Duration

  private var session: (any HostProcessSession)?
  private var ownedSocketIdentity: SocktainerSocketIdentity?
  private var runtimeState: SocktainerRuntimeState = .stopped
  private var stopRequested = false
  private var monitorTask: Task<Void, Never>?

  init(
    socketURL: URL? = nil,
    launcher: any HostProcessLaunching = FoundationHostProcessLauncher(),
    socketInspector: (any SocktainerSocketInspecting)? = nil,
    readinessProbe: any SocktainerReadinessProbing = UnixSocketSocktainerReadinessProbe(),
    environment: [String: String]? = nil,
    startupTimeout: Duration = .seconds(10),
    gracefulStopTimeout: Duration = .seconds(5),
    killConfirmationTimeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(50)
  ) {
    let resolvedSocketURL =
      socketURL
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".socktainer", directoryHint: .isDirectory)
      .appending(path: "container.sock", directoryHint: .notDirectory)
    self.socketURL = resolvedSocketURL
    self.launcher = launcher
    let resolvedSocketInspector =
      socketInspector
      ?? FileSystemSocktainerSocketInspector(socketURL: resolvedSocketURL)
    self.socketInspector = resolvedSocketInspector
    self.readinessProbe = readinessProbe
    terminationSentinel = SocktainerTerminationSentinel(
      socketInspector: resolvedSocketInspector
    )
    self.environment = environment
    self.startupTimeout = startupTimeout
    self.gracefulStopTimeout = gracefulStopTimeout
    self.killConfirmationTimeout = killConfirmationTimeout
    self.pollInterval = pollInterval
  }

  func status() async -> SocktainerRuntimeState {
    if let session {
      if !session.isRunning {
        processDidExit(session)
      } else if case .running = runtimeState {
        do {
          if case .socket(let identity) = try socketInspector.inspectSocket(),
            identity == ownedSocketIdentity
          {
            return runtimeState
          }
          runtimeState = .failed("The app-owned Socktainer socket disappeared.")
          await terminateOwnedProcess(session, gracefulFirst: true)
          return runtimeState
        } catch {
          runtimeState = .failed(error.localizedDescription)
          return runtimeState
        }
      }
      if self.session != nil {
        return runtimeState
      }
    }

    do {
      switch try socketInspector.inspectSocket() {
      case .absent:
        return runtimeState
      case .socket, .unsafe:
        return .blockedByForeignSocket(socketURL)
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  func start(executableURL: URL) async throws {
    if let session, session.isRunning {
      throw DockerCompatibilityError.processAlreadyRunning
    }

    try socketInspector.prepareSocketDirectory()
    switch try socketInspector.inspectSocket() {
    case .absent:
      break
    case .socket, .unsafe:
      runtimeState = .blockedByForeignSocket(socketURL)
      throw DockerCompatibilityError.foreignSocket(socketURL)
    }

    let launched: any HostProcessSession
    do {
      launched = try launcher.launch(
        HostProcessConfiguration(
          executableURL: executableURL,
          environment: environment,
          observeApplicationTermination: true,
          applicationTerminationCleanup: { [terminationSentinel] in
            terminationSentinel.cleanup()
          }
        )
      )
    } catch {
      runtimeState = .failed(error.localizedDescription)
      throw DockerCompatibilityError.processLaunchFailed(error.localizedDescription)
    }

    session = launched
    stopRequested = false
    ownedSocketIdentity = nil
    runtimeState = .starting

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: startupTimeout)
    do {
      while clock.now < deadline {
        try Task.checkCancellation()
        guard launched.isRunning else {
          let output = launched.capturedOutput().combinedForError
          processDidExit(launched)
          throw DockerCompatibilityError.processExitedDuringStartup(output)
        }

        switch try socketInspector.inspectSocket() {
        case .absent:
          try await Task.sleep(for: pollInterval)
        case .socket(let identity):
          guard await readinessProbe.isReady(socketURL: socketURL) else {
            try await Task.sleep(for: pollInterval)
            continue
          }
          guard case .socket(let confirmedIdentity) = try socketInspector.inspectSocket(),
            confirmedIdentity == identity
          else {
            try await Task.sleep(for: pollInterval)
            continue
          }
          ownedSocketIdentity = confirmedIdentity
          terminationSentinel.set(identity: confirmedIdentity)
          runtimeState = .running(processID: launched.processID)
          beginMonitoring(launched)
          return
        case .unsafe:
          throw DockerCompatibilityError.foreignSocket(socketURL)
        }
      }
      throw DockerCompatibilityError.processStartupTimedOut
    } catch {
      await terminateOwnedProcess(launched, gracefulFirst: true)
      if self.session === launched {
        processDidExit(launched)
      }
      throw error
    }
  }

  func stop() async throws {
    guard let session, session.isRunning else {
      throw DockerCompatibilityError.processNotOwned
    }
    stopRequested = true
    runtimeState = .stopping
    await terminateOwnedProcess(session, gracefulFirst: true)
    guard !session.isRunning else {
      throw DockerCompatibilityError.processDidNotExitAfterKill
    }
    processDidExit(session)
  }

  func forceStop() async throws {
    guard let session, session.isRunning else {
      throw DockerCompatibilityError.processNotOwned
    }
    stopRequested = true
    runtimeState = .stopping
    await terminateOwnedProcess(session, gracefulFirst: false)
    guard !session.isRunning else {
      throw DockerCompatibilityError.processDidNotExitAfterKill
    }
    processDidExit(session)
  }

  func removeStaleSocket() async throws {
    guard session == nil else {
      throw DockerCompatibilityError.processAlreadyRunning
    }
    guard case .socket(let identity) = try socketInspector.inspectSocket() else {
      throw DockerCompatibilityError.processNotOwned
    }

    for _ in 0..<3 {
      if await readinessProbe.hasListener(socketURL: socketURL) {
        throw DockerCompatibilityError.foreignSocket(socketURL)
      }
      try await Task.sleep(for: .milliseconds(250))
      guard case .socket(let current) = try socketInspector.inspectSocket(),
        current == identity
      else {
        throw DockerCompatibilityError.foreignSocket(socketURL)
      }
    }

    try socketInspector.removeSocket(ifMatching: identity)
    runtimeState = .stopped
  }

  private func beginMonitoring(_ monitoredSession: any HostProcessSession) {
    monitorTask?.cancel()
    monitorTask = Task { [weak self, monitoredSession] in
      while !Task.isCancelled, monitoredSession.isRunning {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await self?.monitor(monitoredSession)
      }
      await self?.monitor(monitoredSession)
    }
  }

  private func monitor(_ monitoredSession: any HostProcessSession) async {
    guard session === monitoredSession else { return }
    guard monitoredSession.isRunning else {
      processDidExit(monitoredSession)
      return
    }
    guard case .running = runtimeState, let ownedSocketIdentity else { return }

    do {
      guard case .socket(let currentIdentity) = try socketInspector.inspectSocket(),
        currentIdentity == ownedSocketIdentity
      else {
        runtimeState = .failed("The app-owned Socktainer socket disappeared.")
        await terminateOwnedProcess(monitoredSession, gracefulFirst: true)
        processDidExit(monitoredSession)
        return
      }
    } catch {
      runtimeState = .failed(error.localizedDescription)
      await terminateOwnedProcess(monitoredSession, gracefulFirst: true)
      processDidExit(monitoredSession)
    }
  }

  private func terminateOwnedProcess(
    _ ownedSession: any HostProcessSession,
    gracefulFirst: Bool
  ) async {
    if gracefulFirst, ownedSession.isRunning {
      try? ownedSession.send(signal: SIGTERM)
      if await waitForExit(ownedSession, timeout: gracefulStopTimeout) {
        return
      }
    }
    if ownedSession.isRunning {
      try? ownedSession.send(signal: SIGKILL)
    }
    _ = await waitForExit(ownedSession, timeout: killConfirmationTimeout)
  }

  private func waitForExit(
    _ ownedSession: any HostProcessSession,
    timeout: Duration
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while ownedSession.isRunning, clock.now < deadline {
      try? await Task.sleep(for: pollInterval)
    }
    return !ownedSession.isRunning
  }

  private func processDidExit(_ exitedSession: any HostProcessSession) {
    guard session === exitedSession else { return }
    monitorTask?.cancel()
    monitorTask = nil

    if let identity = ownedSocketIdentity {
      try? socketInspector.removeSocket(ifMatching: identity)
      terminationSentinel.clear(ifMatching: identity)
    }
    ownedSocketIdentity = nil
    session = nil

    if stopRequested {
      runtimeState = .stopped
    } else {
      let output = exitedSession.capturedOutput().combinedForError
      let status = exitedSession.terminationStatus.map(String.init) ?? "unknown"
      runtimeState = .failed(
        output.isEmpty
          ? "Socktainer exited unexpectedly with status \(status)."
          : "Socktainer exited unexpectedly with status \(status): \(output)"
      )
    }
    stopRequested = false
  }
}

struct FileSystemSocktainerSocketInspector: SocktainerSocketInspecting {
  let socketURL: URL

  func prepareSocketDirectory() throws {
    let directoryURL = socketURL.deletingLastPathComponent()
    let path = directoryURL.nativeContainersPOSIXPath
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
      guard errno == ENOENT else {
        throw DockerCompatibilityError.unsafeInstallLocation(path)
      }
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false
      )
    } else {
      try validateDirectory(directoryURL)
    }
    guard chmod(path, 0o700) == 0 else {
      throw DockerCompatibilityError.unsafeInstallLocation(path)
    }
    try validateDirectory(directoryURL)
  }

  func inspectSocket() throws -> SocktainerSocketState {
    let path = socketURL.path(percentEncoded: false)
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      if errno == ENOENT { return .absent }
      throw DockerCompatibilityError.foreignSocket(socketURL)
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
      metadata.st_uid == geteuid()
    else {
      return .unsafe(path)
    }
    return .socket(
      SocktainerSocketIdentity(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        owner: UInt32(metadata.st_uid)
      )
    )
  }

  func removeSocket(ifMatching identity: SocktainerSocketIdentity) throws {
    guard case .socket(let current) = try inspectSocket(), current == identity else {
      return
    }
    guard unlink(socketURL.path(percentEncoded: false)) == 0 || errno == ENOENT else {
      throw DockerCompatibilityError.foreignSocket(socketURL)
    }
  }

  private func validateDirectory(_ url: URL) throws {
    let path = url.nativeContainersPOSIXPath
    var metadata = stat()
    guard
      lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw DockerCompatibilityError.unsafeInstallLocation(path)
    }
  }
}

struct UnixSocketSocktainerReadinessProbe: SocktainerReadinessProbing {
  let expectedAPIVersion: String

  init(expectedAPIVersion: String = "1.51") {
    self.expectedAPIVersion = expectedAPIVersion
  }

  func isReady(socketURL: URL) async -> Bool {
    let expectedAPIVersion = expectedAPIVersion
    return await Task.detached(priority: .utility) {
      Self.probe(socketURL: socketURL, expectedAPIVersion: expectedAPIVersion)
    }.value
  }

  func hasListener(socketURL: URL) async -> Bool {
    await Task.detached(priority: .utility) {
      guard let descriptor = Self.connectedSocket(socketURL: socketURL) else {
        return false
      }
      Darwin.close(descriptor)
      return true
    }.value
  }

  private static func probe(
    socketURL: URL,
    expectedAPIVersion: String
  ) -> Bool {
    guard let descriptor = connectedSocket(socketURL: socketURL) else { return false }
    defer { Darwin.close(descriptor) }

    let request = Data(
      "GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
    )
    let sent = request.withUnsafeBytes { bytes -> Bool in
      guard let baseAddress = bytes.baseAddress else { return false }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    guard sent else { return false }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while response.count < 16_384 {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      guard count > 0 else { break }
      response.append(contentsOf: buffer.prefix(count))
      if hasCompleteHTTPResponse(response) { break }
    }
    return isValidPingResponse(response, expectedAPIVersion: expectedAPIVersion)
  }

  private static func connectedSocket(socketURL: URL) -> Int32? {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }

    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        $0,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    _ = withUnsafePointer(to: &timeout) {
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        $0,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }

    let pathBytes = Array(socketURL.path(percentEncoded: false).utf8CString)
    var address = sockaddr_un()
    let maximumPathBytes = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maximumPathBytes else {
      Darwin.close(descriptor)
      return nil
    }
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

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    guard connected == 0 else {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  static func isValidPingResponse(
    _ response: Data,
    expectedAPIVersion: String
  ) -> Bool {
    guard let text = String(data: response, encoding: .utf8),
      let separator = text.range(of: "\r\n\r\n")
    else { return false }

    let headerText = String(text[..<separator.lowerBound])
    let body = text[separator.upperBound...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = headerText.components(separatedBy: "\r\n")
    guard lines.first?.contains(" 200 ") == true, body == "OK" else { return false }
    let apiVersion = lines.dropFirst().first { line in
      line.lowercased().hasPrefix("api-version:")
    }?.split(separator: ":", maxSplits: 1).last?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return apiVersion == expectedAPIVersion
  }

  private static func hasCompleteHTTPResponse(_ response: Data) -> Bool {
    guard let text = String(data: response, encoding: .utf8),
      let separator = text.range(of: "\r\n\r\n")
    else { return false }
    let headers = text[..<separator.lowerBound].components(separatedBy: "\r\n")
    guard
      let contentLengthLine = headers.first(where: {
        $0.lowercased().hasPrefix("content-length:")
      }),
      let contentLength = Int(
        contentLengthLine.split(separator: ":", maxSplits: 1).last?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      )
    else { return false }
    return text[separator.upperBound...].utf8.count >= contentLength
  }
}

final class SocktainerTerminationSentinel: @unchecked Sendable {
  private let socketInspector: any SocktainerSocketInspecting
  private let lock = NSLock()
  private var identity: SocktainerSocketIdentity?

  init(socketInspector: any SocktainerSocketInspecting) {
    self.socketInspector = socketInspector
  }

  func set(identity: SocktainerSocketIdentity) {
    lock.withLock {
      self.identity = identity
    }
  }

  func clear(ifMatching identity: SocktainerSocketIdentity) {
    lock.withLock {
      if self.identity == identity {
        self.identity = nil
      }
    }
  }

  func cleanup() {
    let identity = lock.withLock { () -> SocktainerSocketIdentity? in
      let value = identity
      identity = nil
      return value
    }
    if let identity {
      try? socketInspector.removeSocket(ifMatching: identity)
    }
  }
}
