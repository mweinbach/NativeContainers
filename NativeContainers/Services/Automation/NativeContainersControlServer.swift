import Darwin
import Foundation

@MainActor
protocol NativeContainersControlServing: AnyObject, Sendable {
  func start() throws
  func stopAcceptingMutations()
  func stop()
}

private final class NativeContainersClientSlots: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func acquire() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard count < 16 else { return false }
    count += 1
    return true
  }
  func release() {
    lock.lock(); defer { lock.unlock() }
    count = max(0, count - 1)
  }
}

private final class NativeContainersClientConnections: @unchecked Sendable {
  private let lock = NSLock()
  private var accepting = false
  private var descriptors: Set<Int32> = []

  func beginServing() {
    lock.lock()
    accepting = true
    lock.unlock()
  }

  func register(_ descriptor: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { return false }
    descriptors.insert(descriptor)
    return true
  }

  func unregister(_ descriptor: Int32) {
    lock.lock()
    descriptors.remove(descriptor)
    lock.unlock()
  }

  func stopAndShutdownAll() {
    lock.lock()
    accepting = false
    let active = descriptors
    lock.unlock()
    for descriptor in active {
      Darwin.shutdown(descriptor, SHUT_RDWR)
    }
  }
}

private final class NativeContainersControlAvailability: @unchecked Sendable {
  private let lock = NSLock()
  private var acceptsMutations = false

  func beginServing() {
    lock.lock()
    acceptsMutations = true
    lock.unlock()
  }

  func stopAcceptingMutations() {
    lock.lock()
    acceptsMutations = false
    lock.unlock()
  }

  func permits(_ operation: NativeContainersControlOperation) -> Bool {
    switch operation {
    case .doctor, .list, .status:
      return true
    default:
      lock.lock()
      defer { lock.unlock() }
      return acceptsMutations
    }
  }
}

private enum NativeContainersControlClientError: Error {
  case disconnected
  case extraInput
}

@MainActor
final class NativeContainersControlServer: NativeContainersControlServing, @unchecked Sendable {
  nonisolated static let defaultSocketURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Control", directoryHint: .isDirectory)
      .appending(path: "control-v1.sock")
  }()

  private let socketURL: URL
  private let automation: LinuxBoxAutomationService
  private let slots = NativeContainersClientSlots()
  private let connections = NativeContainersClientConnections()
  private let availability = NativeContainersControlAvailability()
  private var listener: Int32 = -1
  private var acceptTask: Task<Void, Never>?
  private var parentDescriptor: Int32 = -1

  init(
    socketURL: URL? = nil,
    automation: LinuxBoxAutomationService
  ) {
    self.socketURL = (socketURL ?? Self.defaultSocketURL).standardizedFileURL
    self.automation = automation
  }

  deinit {
    if listener >= 0 { Darwin.close(listener) }
    if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
  }

  func start() throws {
    guard listener < 0 else { return }
    let parent = try openAndValidateParent()
    var descriptor: Int32 = -1
    var didBind = false
    do {
      try recoverStaleSocketIfNeeded(parent: parent)
      descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else {
        throw NativeContainersControlServerError.posix(errno)
      }
      guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw NativeContainersControlServerError.posix(errno)
      }
      try withSocketAddress { address, length in
        guard Darwin.bind(descriptor, address, length) == 0 else {
          throw NativeContainersControlServerError.posix(errno)
        }
      }
      didBind = true
      try secureBoundSocket(parent: parent)
      guard Darwin.listen(descriptor, 16) == 0 else {
        throw NativeContainersControlServerError.posix(errno)
      }
    } catch {
      if didBind { try? removeOwnedSocket(parent: parent) }
      if descriptor >= 0 { Darwin.close(descriptor) }
      Darwin.close(parent)
      throw error
    }
    parentDescriptor = parent
    listener = descriptor
    connections.beginServing()
    availability.beginServing()
    let acceptedDescriptor = descriptor
    acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
      while !Task.isCancelled {
        let client = Darwin.accept(acceptedDescriptor, nil, nil)
        guard client >= 0 else {
          if errno == EINTR { continue }
          break
        }
        guard let self else {
          Darwin.close(client)
          break
        }
        guard self.slots.acquire() else {
          Darwin.close(client)
          continue
        }
        guard self.connections.register(client) else {
          self.slots.release()
          Darwin.close(client)
          continue
        }
        Task.detached(priority: .userInitiated) { [weak self] in
          guard let self else {
            Darwin.close(client)
            return
          }
          defer {
            self.connections.unregister(client)
            self.slots.release()
          }
          await self.handle(client: client)
        }
      }
    }
  }

  func stopAcceptingMutations() {
    availability.stopAcceptingMutations()
  }

  func stop() {
    availability.stopAcceptingMutations()
    if listener >= 0 {
      Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
      listener = -1
    }
    connections.stopAndShutdownAll()
    acceptTask?.cancel()
    acceptTask = nil
    if parentDescriptor >= 0 {
      try? removeOwnedSocket(parent: parentDescriptor)
      Darwin.close(parentDescriptor)
      parentDescriptor = -1
    }
  }

  private func openAndValidateParent() throws -> Int32 {
    let parentURL = socketURL.deletingLastPathComponent()
    let existed = FileManager.default.fileExists(atPath: parentURL.path)
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    if !existed {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: parentURL.path
      )
    }
    let descriptor = Darwin.open(
      parentURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw NativeContainersControlServerError.posix(errno) }
    do {
      try validateOwnerOnlyDirectory(descriptor)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }
  private func validateOwnerOnlyDirectory(_ descriptor: Int32) throws {
    var stat = Darwin.stat()
    guard Darwin.fstat(descriptor, &stat) == 0 else {
      throw NativeContainersControlServerError.posix(errno)
    }
    guard (stat.st_mode & S_IFMT) == S_IFDIR else {
      throw NativeContainersControlServerError.invalidSocketDirectory
    }
    guard stat.st_uid == getuid(), mode_t(stat.st_mode & 0o7777) == 0o700 else {
      throw NativeContainersControlServerError.invalidSocketDirectory
    }
  }

  private func recoverStaleSocketIfNeeded(parent: Int32) throws {
    let name = socketURL.lastPathComponent
    var entry = Darwin.stat()
    let result = name.withCString { Darwin.fstatat(parent, $0, &entry, AT_SYMLINK_NOFOLLOW) }
    guard result == 0 else {
      guard errno == ENOENT else {
        throw NativeContainersControlServerError.posix(errno)
      }
      return
    }
    guard (entry.st_mode & S_IFMT) == S_IFSOCK,
      entry.st_uid == getuid(),
      mode_t(entry.st_mode & 0o7777) == 0o600
    else {
      throw NativeContainersControlServerError.occupiedSocketPath
    }
    let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { throw NativeContainersControlServerError.posix(errno) }
    guard Darwin.fcntl(probe, F_SETFD, FD_CLOEXEC) == 0 else {
      let code = errno
      Darwin.close(probe)
      throw NativeContainersControlServerError.posix(code)
    }
    var serverPresent = false
    do {
      try withSocketAddress { address, length in
        if Darwin.connect(probe, address, length) == 0 {
          serverPresent = true
        } else if errno != ECONNREFUSED && errno != ENOENT && errno != ECONNRESET {
          throw NativeContainersControlServerError.posix(errno)
        }
      }
    } catch {
      Darwin.close(probe)
      throw error
    }
    Darwin.close(probe)
    if serverPresent { throw NativeContainersControlServerError.serverAlreadyRunning }

    var confirmed = Darwin.stat()
    let check = name.withCString { Darwin.fstatat(parent, $0, &confirmed, AT_SYMLINK_NOFOLLOW) }
    guard check == 0,
      confirmed.st_dev == entry.st_dev,
      confirmed.st_ino == entry.st_ino,
      (confirmed.st_mode & S_IFMT) == S_IFSOCK,
      confirmed.st_uid == getuid()
    else { throw NativeContainersControlServerError.staleSocketChanged }
    guard name.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0 else {
      throw NativeContainersControlServerError.posix(errno)
    }
  }

  private func secureBoundSocket(parent: Int32) throws {
    let name = socketURL.lastPathComponent
    guard name.withCString({
      Darwin.fchmodat(parent, $0, mode_t(0o600), 0)
    }) == 0 else {
      throw NativeContainersControlServerError.posix(errno)
    }
    var entry = Darwin.stat()
    guard name.withCString({
      Darwin.fstatat(parent, $0, &entry, AT_SYMLINK_NOFOLLOW)
    }) == 0 else {
      throw NativeContainersControlServerError.posix(errno)
    }
    guard (entry.st_mode & S_IFMT) == S_IFSOCK,
      entry.st_uid == getuid(),
      mode_t(entry.st_mode & 0o7777) == 0o600
    else {
      throw NativeContainersControlServerError.occupiedSocketPath
    }
  }

  private func removeOwnedSocket(parent: Int32) throws {
    let name = socketURL.lastPathComponent
    var entry = Darwin.stat()
    guard name.withCString({ Darwin.fstatat(parent, $0, &entry, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      guard errno == ENOENT else { throw NativeContainersControlServerError.posix(errno) }
      return
    }
    guard (entry.st_mode & S_IFMT) == S_IFSOCK, entry.st_uid == getuid() else {
      throw NativeContainersControlServerError.occupiedSocketPath
    }
    guard name.withCString({ Darwin.unlinkat(parent, $0, 0) }) == 0 else {
      throw NativeContainersControlServerError.posix(errno)
    }
  }

  private func withSocketAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
    let path = socketURL.path
    let bytes = Array(path.utf8)
    guard bytes.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw NativeContainersControlServerError.socketPathTooLong
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { destination[index] = byte }
    }
    try withUnsafePointer(to: &address) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  private nonisolated func handle(client: Int32) async {
    defer { Darwin.close(client) }
    guard validatePeer(client) else { return }
    do {
      let payload = try BoundedJSONFrameCodec.readPayload(from: client)
      let request = try NativeContainersControlRequest.decodeStrict(payload)
      guard availability.permits(request.operation) else {
        let response = encodeFailure(
          requestID: request.requestID,
          code: .busy,
          message: "The application is terminating."
        )
        try BoundedJSONFrameCodec.write(
          try BoundedJSONFrameCodec.encodePayload(response),
          to: client
        )
        return
      }
      let response = try await executeWhileCallerConnected(request, client: client)
      let frame = try BoundedJSONFrameCodec.encodePayload(response)
      try BoundedJSONFrameCodec.write(frame, to: client)
    } catch {
      return
    }
  }

  private nonisolated func executeWhileCallerConnected(
    _ request: NativeContainersControlRequest,
    client: Int32
  ) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask {
        do {
          return try await withTimeout(seconds: request.timeoutSeconds) {
            try await self.automation.execute(request)
          }
        } catch let error as NativeContainersAutomationError {
          return encodeFailure(
            requestID: request.requestID,
            code: error.code,
            message: error.safeMessage,
            details: error.details
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          return encodeFailure(
            requestID: request.requestID,
            code: .internalError,
            message: "The operation could not be completed."
          )
        }
      }
      group.addTask {
        try await self.waitForCallerViolation(client)
      }
      guard let response = try await group.next() else {
        throw NativeContainersControlClientError.disconnected
      }
      try rejectBufferedCallerInput(client)
      guard Darwin.shutdown(client, SHUT_RD) == 0 || errno == ENOTCONN else {
        throw NativeContainersControlServerError.posix(errno)
      }
      group.cancelAll()
      return response
    }
  }

  private nonisolated func rejectBufferedCallerInput(_ descriptor: Int32) throws {
    while true {
      var byte: UInt8 = 0
      let received = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
      if received > 0 { throw NativeContainersControlClientError.extraInput }
      if received == 0 { throw NativeContainersControlClientError.disconnected }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }
      throw NativeContainersControlServerError.posix(errno)
    }
  }

  private nonisolated func waitForCallerViolation(_ descriptor: Int32) async throws -> Data {
    while !Task.isCancelled {
      var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let result = Darwin.poll(&descriptorState, 1, 100)
      if result < 0 {
        if errno == EINTR { continue }
        throw NativeContainersControlServerError.posix(errno)
      }
      if result == 0 { continue }
      var byte: UInt8 = 0
      let received = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
      if received > 0 { throw NativeContainersControlClientError.extraInput }
      if received == 0 { throw NativeContainersControlClientError.disconnected }
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw NativeContainersControlServerError.posix(errno)
    }
    throw CancellationError()
  }

  private nonisolated func validatePeer(_ descriptor: Int32) -> Bool {
    var effectiveUID: uid_t = 0
    var effectiveGID: gid_t = 0
    guard getpeereid(descriptor, &effectiveUID, &effectiveGID) == 0 else { return false }
    return effectiveUID == getuid()
  }

}

private struct NativeContainersControlFailureResponse: Encodable {
  let schemaVersion: Int
  let requestID: CanonicalUUID
  let ok = false
  let data: String? = nil
  let error: NativeContainersControlFailure
}

private func encodeFailure(
  requestID: CanonicalUUID,
  code: NativeContainersControlErrorCode,
  message: String,
  details: LinuxBoxExecResult? = nil
) -> Data {
  (try? JSONEncoder().encode(
    NativeContainersControlFailureResponse(
      schemaVersion: NativeContainersControlProtocol.schemaVersion,
      requestID: requestID,
      error: NativeContainersControlFailure(
        code: code,
        message: NativeContainersControlRedactor.message(message),
        details: details
      )
    )
  )) ?? Data("{\"schemaVersion\":1,\"requestID\":\"\(requestID.value.uuidString.lowercased())\",\"ok\":false}".utf8)
}

private func withTimeout<Value: Sendable>(
  seconds: Int,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask(operation: operation)
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw NativeContainersAutomationError.deadline
    }
    guard let result = try await group.next() else { throw NativeContainersAutomationError.deadline }
    group.cancelAll()
    return result
  }
}

enum NativeContainersControlServerError: Error, Equatable, LocalizedError, Sendable {
  case posix(Int32)
  case invalidSocketDirectory
  case occupiedSocketPath
  case staleSocketChanged
  case serverAlreadyRunning
  case socketPathTooLong

  var errorDescription: String? {
    switch self {
    case .posix(let code): "The control socket operation failed (errno \(code))."
    case .invalidSocketDirectory: "The control socket directory must be owner-only."
    case .occupiedSocketPath: "The control socket path is not an owner-only Unix socket."
    case .staleSocketChanged: "The stale control socket changed during recovery."
    case .serverAlreadyRunning: "A NativeContainers control server is already running."
    case .socketPathTooLong: "The control socket path is too long."
    }
  }
}
