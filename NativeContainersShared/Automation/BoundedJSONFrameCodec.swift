import Darwin
import Foundation

enum BoundedJSONFrameError: Error, Equatable, LocalizedError, Sendable {
  case emptyFrame
  case frameTooLarge(actualBytes: Int, maximumBytes: Int)
  case truncatedHeader(receivedBytes: Int)
  case truncatedPayload(expectedBytes: Int, receivedBytes: Int)
  case encodingFailed(String)
  case decodingFailed(String)
  case inputReadFailed(code: Int32)
  case outputWriteFailed(code: Int32)

  var errorDescription: String? {
    switch self {
    case .emptyFrame:
      "The JSON control stream sent an empty frame."
    case .frameTooLarge(let actualBytes, let maximumBytes):
      "The JSON control frame is \(actualBytes) bytes; the limit is \(maximumBytes) bytes."
    case .truncatedHeader(let receivedBytes):
      "The JSON control stream ended after \(receivedBytes) of 4 frame-header bytes."
    case .truncatedPayload(let expectedBytes, let receivedBytes):
      "The JSON control stream ended after \(receivedBytes) of \(expectedBytes) payload bytes."
    case .encodingFailed(let message):
      "The JSON control value could not be encoded: \(message)"
    case .decodingFailed(let message):
      "The JSON control frame could not be decoded: \(message)"
    case .inputReadFailed(let code):
      "The JSON control stream could not be read (errno \(code))."
    case .outputWriteFailed(let code):
      "The JSON control stream could not be written (errno \(code))."
    }
  }
}

enum BoundedJSONFrameCodec {
  static let headerBytes = 4
  static let maximumPayloadBytes = 1_024 * 1_024

  static func encode<Value: Encodable>(
    _ value: Value,
    using encoder: JSONEncoder = JSONEncoder()
  ) throws -> Data {
    let payload: Data
    do {
      payload = try encoder.encode(value)
    } catch {
      throw BoundedJSONFrameError.encodingFailed(error.localizedDescription)
    }
    return try encodePayload(payload)
  }

  static func encodePayload(_ payload: Data) throws -> Data {
    guard !payload.isEmpty else {
      throw BoundedJSONFrameError.emptyFrame
    }
    guard payload.count <= maximumPayloadBytes else {
      throw BoundedJSONFrameError.frameTooLarge(
        actualBytes: payload.count,
        maximumBytes: maximumPayloadBytes
      )
    }

    let length = UInt32(payload.count)
    var frame = Data(capacity: headerBytes + payload.count)
    frame.append(UInt8((length >> 24) & 0xff))
    frame.append(UInt8((length >> 16) & 0xff))
    frame.append(UInt8((length >> 8) & 0xff))
    frame.append(UInt8(length & 0xff))
    frame.append(payload)
    return frame
  }

  static func readPayload(from descriptor: Int32) throws -> Data {
    let header = try readExactly(
      from: descriptor,
      count: headerBytes,
      truncated: { .truncatedHeader(receivedBytes: $0) }
    )
    let length =
      (UInt32(header[header.startIndex]) << 24)
      | (UInt32(header[header.startIndex + 1]) << 16)
      | (UInt32(header[header.startIndex + 2]) << 8)
      | UInt32(header[header.startIndex + 3])
    guard length > 0 else {
      throw BoundedJSONFrameError.emptyFrame
    }
    guard length <= UInt32(maximumPayloadBytes) else {
      throw BoundedJSONFrameError.frameTooLarge(
        actualBytes: Int(length),
        maximumBytes: maximumPayloadBytes
      )
    }
    return try readExactly(
      from: descriptor,
      count: Int(length),
      truncated: {
        .truncatedPayload(expectedBytes: Int(length), receivedBytes: $0)
      }
    )
  }

  static func decode<Value: Decodable & Sendable>(
    _ type: Value.Type = Value.self,
    from descriptor: Int32,
    using decoder: JSONDecoder = JSONDecoder()
  ) throws -> Value {
    let payload = try readPayload(from: descriptor)
    do {
      return try decoder.decode(type, from: payload)
    } catch {
      throw BoundedJSONFrameError.decodingFailed(error.localizedDescription)
    }
  }

  static func write(_ frame: Data, to descriptor: Int32) throws {
    var offset = 0
    try frame.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let result = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw BoundedJSONFrameError.outputWriteFailed(code: errno)
        }
        guard result > 0 else {
          throw BoundedJSONFrameError.outputWriteFailed(code: EIO)
        }
        offset += result
      }
    }
  }

  static func readExactly(
    from descriptor: Int32,
    count: Int,
    truncated: (Int) -> BoundedJSONFrameError
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
          throw BoundedJSONFrameError.inputReadFailed(code: errno)
        }
        guard result > 0 else { throw truncated(offset) }
        offset += result
      }
    }
    return data
  }
}

enum BoundedJSONFramedInput {
  static func readOne<Value: Decodable & Sendable>(
    from descriptor: Int32,
    as type: Value.Type = Value.self,
    using decoder: JSONDecoder = JSONDecoder()
  ) throws -> Value {
    try BoundedJSONFrameCodec.decode(type, from: descriptor, using: decoder)
  }
}

struct BoundedJSONFrameDecoder<Value: Decodable & Sendable>: Sendable {
  private var buffer = Data()
  private var expectedPayloadBytes: Int?
  private let decoder: JSONDecoder

  init(decoder: JSONDecoder = JSONDecoder()) {
    self.decoder = decoder
  }

  mutating func append(_ data: Data) throws -> [Value] {
    if !data.isEmpty { buffer.append(data) }

    var decoded: [Value] = []
    while true {
      if expectedPayloadBytes == nil {
        guard buffer.count >= BoundedJSONFrameCodec.headerBytes else { break }
        let length =
          (UInt32(buffer[buffer.startIndex]) << 24)
          | (UInt32(buffer[buffer.startIndex + 1]) << 16)
          | (UInt32(buffer[buffer.startIndex + 2]) << 8)
          | UInt32(buffer[buffer.startIndex + 3])
        buffer.removeFirst(BoundedJSONFrameCodec.headerBytes)
        guard length > 0 else {
          throw BoundedJSONFrameError.emptyFrame
        }
        guard length <= UInt32(BoundedJSONFrameCodec.maximumPayloadBytes) else {
          throw BoundedJSONFrameError.frameTooLarge(
            actualBytes: Int(length),
            maximumBytes: BoundedJSONFrameCodec.maximumPayloadBytes
          )
        }
        expectedPayloadBytes = Int(length)
      }

      guard let expectedPayloadBytes, buffer.count >= expectedPayloadBytes else { break }
      let payload = Data(buffer.prefix(expectedPayloadBytes))
      buffer.removeFirst(expectedPayloadBytes)
      self.expectedPayloadBytes = nil
      do {
        decoded.append(try decoder.decode(Value.self, from: payload))
      } catch {
        throw BoundedJSONFrameError.decodingFailed(error.localizedDescription)
      }
    }
    return decoded
  }

  func finish() throws {
    if let expectedPayloadBytes {
      throw BoundedJSONFrameError.truncatedPayload(
        expectedBytes: expectedPayloadBytes,
        receivedBytes: buffer.count
      )
    }
    guard buffer.isEmpty else {
      throw BoundedJSONFrameError.truncatedHeader(receivedBytes: buffer.count)
    }
  }
}
