import Darwin
import Foundation

protocol LinuxVirtualMachineAgentTransport: Sendable {
  func readFrame(timeout: Duration) async throws -> Data
  func writeFrame(_ frame: Data, timeout: Duration) async throws
  func close()
}

enum LinuxVirtualMachineAgentTransportError: LocalizedError, Equatable, Sendable {
  case closed
  case timedOut
  case invalidFrameLength(Int)
  case readFailed(Int32)
  case writeFailed(Int32)
  case configurationFailed(Int32)

  var errorDescription: String? {
    switch self {
    case .closed:
      "The Linux box guest-agent connection closed."
    case .timedOut:
      "The Linux box guest-agent connection timed out."
    case .invalidFrameLength(let length):
      "The Linux box guest agent sent an invalid frame length (\(length))."
    case .readFailed(let code):
      "The Linux box guest-agent connection could not be read (errno \(code))."
    case .writeFailed(let code):
      "The Linux box guest-agent connection could not be written (errno \(code))."
    case .configurationFailed(let code):
      "The Linux box guest-agent descriptor could not be configured (errno \(code))."
    }
  }
}

final class POSIXLinuxVirtualMachineAgentTransport: LinuxVirtualMachineAgentTransport,
  @unchecked Sendable
{
  private let descriptor: Int32
  private let closeAction: @Sendable () -> Void
  private let readQueue: DispatchQueue
  private let writeQueue: DispatchQueue
  private let stateLock = NSLock()
  private var isClosed = false

  init(
    descriptor: Int32,
    label: String,
    closeAction: @escaping @Sendable () -> Void
  ) throws {
    guard descriptor >= 0 else {
      throw LinuxVirtualMachineAgentTransportError.closed
    }
    self.descriptor = descriptor
    self.closeAction = closeAction
    readQueue = DispatchQueue(label: "\(label).read", qos: .userInitiated)
    writeQueue = DispatchQueue(label: "\(label).write", qos: .userInitiated)

    let descriptorFlags = fcntl(descriptor, F_GETFD)
    guard descriptorFlags >= 0,
      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else {
      throw LinuxVirtualMachineAgentTransportError.configurationFailed(errno)
    }
    let statusFlags = fcntl(descriptor, F_GETFL)
    guard statusFlags >= 0,
      fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
    else {
      throw LinuxVirtualMachineAgentTransportError.configurationFailed(errno)
    }
  }

  deinit {
    close()
  }

  func readFrame(timeout: Duration) async throws -> Data {
    try await perform(on: readQueue, timeout: timeout) { [self] deadline in
      let header = try readExactly(count: BoundedJSONFrameCodec.headerBytes, deadline: deadline)
      let length =
        (UInt32(header[header.startIndex]) << 24)
        | (UInt32(header[header.startIndex + 1]) << 16)
        | (UInt32(header[header.startIndex + 2]) << 8)
        | UInt32(header[header.startIndex + 3])
      guard length > 0,
        length <= UInt32(BoundedJSONFrameCodec.maximumPayloadBytes)
      else {
        throw LinuxVirtualMachineAgentTransportError.invalidFrameLength(Int(length))
      }
      return try readExactly(count: Int(length), deadline: deadline)
    }
  }

  func writeFrame(_ frame: Data, timeout: Duration) async throws {
    guard frame.count >= BoundedJSONFrameCodec.headerBytes + 1,
      frame.count <= BoundedJSONFrameCodec.headerBytes
        + BoundedJSONFrameCodec.maximumPayloadBytes
    else {
      throw LinuxVirtualMachineAgentTransportError.invalidFrameLength(
        max(0, frame.count - BoundedJSONFrameCodec.headerBytes)
      )
    }
    try await perform(on: writeQueue, timeout: timeout) { [self] deadline in
      var offset = 0
      try frame.withUnsafeBytes { bytes in
        while offset < bytes.count {
          try wait(for: Int16(POLLOUT), deadline: deadline)
          let result = Darwin.write(
            descriptor,
            bytes.baseAddress!.advanced(by: offset),
            bytes.count - offset
          )
          if result < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            if errno == EBADF || errno == EPIPE { throw LinuxVirtualMachineAgentTransportError.closed }
            throw LinuxVirtualMachineAgentTransportError.writeFailed(errno)
          }
          guard result > 0 else {
            throw LinuxVirtualMachineAgentTransportError.writeFailed(EIO)
          }
          offset += result
        }
      }
    }
  }

  func close() {
    stateLock.lock()
    guard !isClosed else {
      stateLock.unlock()
      return
    }
    isClosed = true
    stateLock.unlock()
    closeAction()
  }

  private func perform<Value: Sendable>(
    on queue: DispatchQueue,
    timeout: Duration,
    operation: @escaping @Sendable (ContinuousClock.Instant) throws -> Value
  ) async throws -> Value {
    guard timeout > .zero else {
      throw LinuxVirtualMachineAgentTransportError.timedOut
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            try requireOpen()
            continuation.resume(returning: try operation(deadline))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      self.close()
    }
  }

  private func requireOpen() throws {
    stateLock.lock()
    let closed = isClosed
    stateLock.unlock()
    if closed { throw LinuxVirtualMachineAgentTransportError.closed }
  }

  private func readExactly(
    count: Int,
    deadline: ContinuousClock.Instant
  ) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
      while offset < count {
        try wait(for: Int16(POLLIN), deadline: deadline)
        let result = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          count - offset
        )
        if result < 0 {
          if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
          if errno == EBADF { throw LinuxVirtualMachineAgentTransportError.closed }
          throw LinuxVirtualMachineAgentTransportError.readFailed(errno)
        }
        guard result > 0 else { throw LinuxVirtualMachineAgentTransportError.closed }
        offset += result
      }
    }
    return data
  }

  private func wait(
    for events: Int16,
    deadline: ContinuousClock.Instant
  ) throws {
    while true {
      try requireOpen()
      let timeout = try pollTimeout(until: deadline)
      var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
      let result = Darwin.poll(&pollDescriptor, 1, timeout)
      if result < 0 {
        if errno == EINTR { continue }
        if errno == EBADF { throw LinuxVirtualMachineAgentTransportError.closed }
        throw events == Int16(POLLIN)
          ? LinuxVirtualMachineAgentTransportError.readFailed(errno)
          : LinuxVirtualMachineAgentTransportError.writeFailed(errno)
      }
      guard result > 0 else { throw LinuxVirtualMachineAgentTransportError.timedOut }
      if pollDescriptor.revents & Int16(POLLNVAL) != 0 {
        throw LinuxVirtualMachineAgentTransportError.closed
      }
      if pollDescriptor.revents & events != 0 { return }
      if pollDescriptor.revents & (Int16(POLLERR) | Int16(POLLHUP)) != 0 {
        throw LinuxVirtualMachineAgentTransportError.closed
      }
    }
  }

  private func pollTimeout(until deadline: ContinuousClock.Instant) throws -> Int32 {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw LinuxVirtualMachineAgentTransportError.timedOut
    }
    let components = remaining.components
    let maximumSeconds = Int64(Int32.max / 1_000)
    if components.seconds >= maximumSeconds { return Int32.max }
    let milliseconds = components.seconds * 1_000
      + (components.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    return Int32(clamping: max(1, milliseconds))
  }
}
