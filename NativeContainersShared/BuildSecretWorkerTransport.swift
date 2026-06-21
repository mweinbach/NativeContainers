import Darwin
import Foundation

enum ContainerBuildSecretLimits {
  static let maximumCount = 32
  static let maximumSecretBytes = 500 * 1_024
  static let maximumTotalBytes = 1_024 * 1_024
}

enum ContainerBuildSecretTransportError: LocalizedError, Equatable, Sendable {
  case tooManySecrets(maximum: Int)
  case invalidIdentifier(String)
  case duplicateIdentifier(String)
  case secretTooLarge(id: String, byteCount: Int, maximum: Int)
  case totalTooLarge(byteCount: Int, maximum: Int)
  case payloadMismatch
  case payloadAlreadyConsumed
  case truncatedPayload
  case payloadReadFailed(code: Int32)
  case payloadWriteFailed(code: Int32)

  var errorDescription: String? {
    switch self {
    case .tooManySecrets(let maximum):
      "The secret payload exceeds the \(maximum)-entry limit."
    case .invalidIdentifier:
      "The secret payload contains an invalid identifier."
    case .duplicateIdentifier:
      "The secret payload contains a duplicate identifier."
    case .secretTooLarge(_, let byteCount, let maximum):
      "A secret payload is \(byteCount) bytes; the limit is \(maximum) bytes."
    case .totalTooLarge(let byteCount, let maximum):
      "The secret payload totals \(byteCount) bytes; the limit is \(maximum) bytes."
    case .payloadMismatch:
      "The build worker secret payload did not match the reviewed secret IDs."
    case .payloadAlreadyConsumed:
      "The one-shot build worker secret payload was already consumed."
    case .truncatedPayload:
      "The build worker secret payload ended before all reviewed bytes arrived."
    case .payloadReadFailed(let code):
      "The build worker secret channel could not be read (errno \(code))."
    case .payloadWriteFailed(let code):
      "The build worker secret channel could not be written (errno \(code))."
    }
  }
}

enum ContainerBuildSecretIDPolicy {
  static func validate(_ identifiers: [String]) throws {
    guard identifiers.count <= ContainerBuildSecretLimits.maximumCount else {
      throw ContainerBuildSecretTransportError.tooManySecrets(
        maximum: ContainerBuildSecretLimits.maximumCount
      )
    }
    var unique = Set<String>()
    for identifier in identifiers {
      try validate(identifier)
      guard unique.insert(identifier).inserted else {
        throw ContainerBuildSecretTransportError.duplicateIdentifier(identifier)
      }
    }
  }

  static func validate(_ identifier: String) throws {
    let bytes = Array(identifier.utf8)
    guard
      (1...128).contains(bytes.count),
      let first = bytes.first,
      isASCIIAlphaNumeric(first),
      bytes.allSatisfy({
        isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
      })
    else {
      throw ContainerBuildSecretTransportError.invalidIdentifier(identifier)
    }
  }

  private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
      || (0x61...0x7A).contains(byte)
  }
}

protocol ContainerBuildSecretStreamingEntry: AnyObject, Sendable {
  var id: String { get }
  var byteCount: Int { get }
  func writeBytes(to descriptor: Int32) throws
}

struct ContainerBuildSecretSourcePayload: @unchecked Sendable {
  private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [any ContainerBuildSecretStreamingEntry]?

    init(entries: [any ContainerBuildSecretStreamingEntry]) {
      self.entries = entries
    }

    func takeEntries() throws -> [any ContainerBuildSecretStreamingEntry] {
      try lock.withLock {
        guard let entries else {
          throw ContainerBuildSecretTransportError.payloadAlreadyConsumed
        }
        self.entries = nil
        return entries
      }
    }
  }

  private let storage: Storage
  let ids: [String]
  let byteCounts: [Int]

  var isEmpty: Bool { ids.isEmpty }

  static var empty: ContainerBuildSecretSourcePayload {
    try! ContainerBuildSecretSourcePayload(entries: [])
  }

  init(entries: [any ContainerBuildSecretStreamingEntry]) throws {
    let sorted = entries.sorted {
      $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
    }
    try ContainerBuildSecretIDPolicy.validate(sorted.map(\.id))
    try Self.validateSizes(sorted.map { ($0.id, $0.byteCount) })
    storage = Storage(entries: sorted)
    ids = sorted.map(\.id)
    byteCounts = sorted.map(\.byteCount)
  }

  fileprivate func takeEntries() throws -> [any ContainerBuildSecretStreamingEntry] {
    try storage.takeEntries()
  }

  private static func validateSizes(_ values: [(String, Int)]) throws {
    var total = 0
    for (id, byteCount) in values {
      guard byteCount >= 0, byteCount <= ContainerBuildSecretLimits.maximumSecretBytes else {
        throw ContainerBuildSecretTransportError.secretTooLarge(
          id: id,
          byteCount: byteCount,
          maximum: ContainerBuildSecretLimits.maximumSecretBytes
        )
      }
      total += byteCount
      guard total <= ContainerBuildSecretLimits.maximumTotalBytes else {
        throw ContainerBuildSecretTransportError.totalTooLarge(
          byteCount: total,
          maximum: ContainerBuildSecretLimits.maximumTotalBytes
        )
      }
    }
  }
}

struct ContainerBuildSecretValues: @unchecked Sendable {
  struct Entry: Sendable {
    let id: String
    let data: Data
  }

  private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Entry]?

    init(entries: [Entry]) {
      self.entries = entries
    }

    func takeEntries() throws -> [Entry] {
      try lock.withLock {
        guard let entries else {
          throw ContainerBuildSecretTransportError.payloadAlreadyConsumed
        }
        self.entries = nil
        return entries
      }
    }
  }

  private let storage: Storage
  let ids: [String]

  var isEmpty: Bool { ids.isEmpty }

  init(entries: [Entry]) throws {
    let sorted = entries.sorted {
      $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
    }
    try ContainerBuildSecretIDPolicy.validate(sorted.map(\.id))
    var total = 0
    for entry in sorted {
      guard entry.data.count <= ContainerBuildSecretLimits.maximumSecretBytes else {
        throw ContainerBuildSecretTransportError.secretTooLarge(
          id: entry.id,
          byteCount: entry.data.count,
          maximum: ContainerBuildSecretLimits.maximumSecretBytes
        )
      }
      total += entry.data.count
      guard total <= ContainerBuildSecretLimits.maximumTotalBytes else {
        throw ContainerBuildSecretTransportError.totalTooLarge(
          byteCount: total,
          maximum: ContainerBuildSecretLimits.maximumTotalBytes
        )
      }
    }
    storage = Storage(entries: sorted)
    ids = sorted.map(\.id)
  }

  func consume(
    _ operation: ([String: Data]) async throws -> Void
  ) async throws {
    let entries = try storage.takeEntries()
    try await operation(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.data) }))
  }
}

struct ContainerBuildWorkerInvocation: Sendable {
  let request: ContainerBuildWorkerRequest
  let secrets: ContainerBuildSecretValues
}

enum ContainerBuildWorkerInvocationInput {
  static func read(from descriptor: Int32) throws -> ContainerBuildWorkerInvocation {
    let header = try readExactly(
      from: descriptor,
      count: 4,
      truncated: { received in
        ContainerBuildWorkerFrameError.truncatedHeader(receivedBytes: received)
      }
    )
    let length =
      (UInt32(header[header.startIndex]) << 24)
      | (UInt32(header[header.startIndex + 1]) << 16)
      | (UInt32(header[header.startIndex + 2]) << 8)
      | UInt32(header[header.startIndex + 3])
    guard length > 0 else {
      throw ContainerBuildWorkerFrameError.emptyFrame
    }
    guard length <= UInt32(ContainerBuildWorkerFrameCodec.maximumPayloadBytes) else {
      throw ContainerBuildWorkerFrameError.frameTooLarge(
        actualBytes: Int(length),
        maximumBytes: ContainerBuildWorkerFrameCodec.maximumPayloadBytes
      )
    }
    let payload = try readExactly(
      from: descriptor,
      count: Int(length),
      truncated: { received in
        ContainerBuildWorkerFrameError.truncatedPayload(
          expectedBytes: Int(length),
          receivedBytes: received
        )
      }
    )

    let request: ContainerBuildWorkerRequest
    do {
      request = try JSONDecoder().decode(ContainerBuildWorkerRequest.self, from: payload)
    } catch {
      throw ContainerBuildWorkerFrameError.decodingFailed(error.localizedDescription)
    }
    let secrets = try ContainerBuildSecretWire.read(
      from: descriptor,
      expectedIDs: request.build?.secretIDs ?? []
    )
    return ContainerBuildWorkerInvocation(request: request, secrets: secrets)
  }

  private static func readExactly(
    from descriptor: Int32,
    count: Int,
    truncated: (Int) -> any Error
  ) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
      while offset < count {
        let result = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          count - offset
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw ContainerBuildWorkerFrameError.inputReadFailed(code: errno)
        }
        guard result > 0 else { throw truncated(offset) }
        offset += result
      }
    }
    return data
  }
}

enum ContainerBuildSecretWire {
  private static let commitMarker: UInt8 = 0xA5

  static func write(
    _ payload: ContainerBuildSecretSourcePayload,
    to descriptor: Int32
  ) throws {
    let entries = try payload.takeEntries()
    try writeUInt32(UInt32(entries.count), to: descriptor)
    for entry in entries {
      let identifier = Array(entry.id.utf8)
      try writeUInt16(UInt16(identifier.count), to: descriptor)
      try writeAll(identifier, to: descriptor)
      try writeUInt32(UInt32(entry.byteCount), to: descriptor)
      try entry.writeBytes(to: descriptor)
    }
    try writeAll([commitMarker], to: descriptor)
  }

  static func read(
    from descriptor: Int32,
    expectedIDs: [String]
  ) throws -> ContainerBuildSecretValues {
    try ContainerBuildSecretIDPolicy.validate(expectedIDs)
    let count = Int(try readUInt32(from: descriptor))
    guard count == expectedIDs.count, count <= ContainerBuildSecretLimits.maximumCount else {
      throw ContainerBuildSecretTransportError.payloadMismatch
    }

    var entries: [ContainerBuildSecretValues.Entry] = []
    entries.reserveCapacity(count)
    var totalBytes = 0
    for expectedID in expectedIDs {
      let identifierByteCount = Int(try readUInt16(from: descriptor))
      guard (1...128).contains(identifierByteCount) else {
        throw ContainerBuildSecretTransportError.payloadMismatch
      }
      let identifierData = try readExactly(from: descriptor, count: identifierByteCount)
      guard
        let identifier = String(data: identifierData, encoding: .utf8),
        identifier == expectedID
      else {
        throw ContainerBuildSecretTransportError.payloadMismatch
      }

      let byteCount = Int(try readUInt32(from: descriptor))
      guard byteCount <= ContainerBuildSecretLimits.maximumSecretBytes else {
        throw ContainerBuildSecretTransportError.secretTooLarge(
          id: expectedID,
          byteCount: byteCount,
          maximum: ContainerBuildSecretLimits.maximumSecretBytes
        )
      }
      totalBytes += byteCount
      guard totalBytes <= ContainerBuildSecretLimits.maximumTotalBytes else {
        throw ContainerBuildSecretTransportError.totalTooLarge(
          byteCount: totalBytes,
          maximum: ContainerBuildSecretLimits.maximumTotalBytes
        )
      }
      let data = try readExactly(from: descriptor, count: byteCount)
      entries.append(ContainerBuildSecretValues.Entry(id: identifier, data: data))
    }
    let marker = try readExactly(from: descriptor, count: 1)
    guard marker.first == commitMarker else {
      throw ContainerBuildSecretTransportError.payloadMismatch
    }
    return try ContainerBuildSecretValues(entries: entries)
  }

  private static func readUInt16(from descriptor: Int32) throws -> UInt16 {
    let data = try readExactly(from: descriptor, count: 2)
    return (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
  }

  private static func readUInt32(from descriptor: Int32) throws -> UInt32 {
    let data = try readExactly(from: descriptor, count: 4)
    return
      (UInt32(data[data.startIndex]) << 24)
      | (UInt32(data[data.startIndex + 1]) << 16)
      | (UInt32(data[data.startIndex + 2]) << 8)
      | UInt32(data[data.startIndex + 3])
  }

  private static func readExactly(from descriptor: Int32, count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
      while offset < count {
        let result = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          count - offset
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw ContainerBuildSecretTransportError.payloadReadFailed(code: errno)
        }
        guard result > 0 else {
          throw ContainerBuildSecretTransportError.truncatedPayload
        }
        offset += result
      }
    }
    return data
  }

  private static func writeUInt16(_ value: UInt16, to descriptor: Int32) throws {
    try writeAll(
      [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)],
      to: descriptor
    )
  }

  private static func writeUInt32(_ value: UInt32, to descriptor: Int32) throws {
    try writeAll(
      [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
      ],
      to: descriptor
    )
  }

  private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
    var offset = 0
    try bytes.withUnsafeBytes { buffer in
      while offset < bytes.count {
        let result = Darwin.write(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: errno)
        }
        guard result > 0 else {
          throw ContainerBuildSecretTransportError.payloadWriteFailed(code: EIO)
        }
        offset += result
      }
    }
  }
}
