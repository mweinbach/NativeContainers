import Darwin
import Foundation

enum ContainerBuildWorkerFrameError: Error, Equatable, LocalizedError, Sendable {
  case emptyFrame
  case frameTooLarge(actualBytes: Int, maximumBytes: Int)
  case truncatedHeader(receivedBytes: Int)
  case truncatedPayload(expectedBytes: Int, receivedBytes: Int)
  case encodingFailed(String)
  case decodingFailed(String)
  case inputReadFailed(code: Int32)

  var errorDescription: String? {
    switch self {
    case .emptyFrame:
      "The build worker sent an empty control frame."
    case .frameTooLarge(let actualBytes, let maximumBytes):
      "The build-worker control frame is \(actualBytes) bytes; the limit is \(maximumBytes) bytes."
    case .truncatedHeader(let receivedBytes):
      "The build-worker stream ended after \(receivedBytes) of 4 frame-header bytes."
    case .truncatedPayload(let expectedBytes, let receivedBytes):
      "The build-worker stream ended after \(receivedBytes) of \(expectedBytes) payload bytes."
    case .encodingFailed(let message):
      "The build-worker control value could not be encoded: \(message)"
    case .decodingFailed(let message):
      "The build-worker control frame could not be decoded: \(message)"
    case .inputReadFailed(let code):
      "The build-worker control stream could not be read (errno \(code))."
    }
  }
}

enum ContainerBuildWorkerFramedInput {
  static func readOne<Value: Decodable & Sendable>(
    from descriptor: Int32,
    as type: Value.Type = Value.self
  ) throws -> Value {
    var decoder = ContainerBuildWorkerFrameDecoder<Value>()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw ContainerBuildWorkerFrameError.inputReadFailed(code: errno)
      }
      guard count > 0 else {
        try decoder.finish()
        throw ContainerBuildWorkerFrameError.truncatedHeader(receivedBytes: 0)
      }

      let values = try decoder.append(Data(buffer[0..<count]))
      guard values.count <= 1 else {
        throw ContainerBuildWorkerFrameError.decodingFailed(
          "exactly one request frame is allowed"
        )
      }
      if let value = values.first { return value }
    }
  }
}

enum ContainerBuildWorkerFrameCodec {
  static let maximumPayloadBytes = 1_024 * 1_024

  static func encode<Value: Encodable>(
    _ value: Value,
    using encoder: JSONEncoder = JSONEncoder()
  ) throws -> Data {
    let payload: Data
    do {
      payload = try encoder.encode(value)
    } catch {
      throw ContainerBuildWorkerFrameError.encodingFailed(error.localizedDescription)
    }
    return try encodePayload(payload)
  }

  static func encodePayload(_ payload: Data) throws -> Data {
    guard !payload.isEmpty else {
      throw ContainerBuildWorkerFrameError.emptyFrame
    }
    guard payload.count <= maximumPayloadBytes else {
      throw ContainerBuildWorkerFrameError.frameTooLarge(
        actualBytes: payload.count,
        maximumBytes: maximumPayloadBytes
      )
    }

    let length = UInt32(payload.count)
    var frame = Data(capacity: 4 + payload.count)
    frame.append(UInt8((length >> 24) & 0xFF))
    frame.append(UInt8((length >> 16) & 0xFF))
    frame.append(UInt8((length >> 8) & 0xFF))
    frame.append(UInt8(length & 0xFF))
    frame.append(payload)
    return frame
  }
}

struct ContainerBuildWorkerFrameDecoder<Value: Decodable & Sendable>: Sendable {
  private var buffer = Data()
  private var expectedPayloadBytes: Int?

  mutating func append(_ data: Data) throws -> [Value] {
    if !data.isEmpty {
      buffer.append(data)
    }

    var decoded: [Value] = []
    while true {
      if expectedPayloadBytes == nil {
        guard buffer.count >= 4 else { break }
        let length =
          (UInt32(buffer[buffer.startIndex]) << 24)
          | (UInt32(buffer[buffer.startIndex + 1]) << 16)
          | (UInt32(buffer[buffer.startIndex + 2]) << 8)
          | UInt32(buffer[buffer.startIndex + 3])
        buffer.removeFirst(4)

        guard length > 0 else {
          throw ContainerBuildWorkerFrameError.emptyFrame
        }
        guard length <= UInt32(ContainerBuildWorkerFrameCodec.maximumPayloadBytes) else {
          throw ContainerBuildWorkerFrameError.frameTooLarge(
            actualBytes: Int(length),
            maximumBytes: ContainerBuildWorkerFrameCodec.maximumPayloadBytes
          )
        }
        expectedPayloadBytes = Int(length)
      }

      guard let expectedPayloadBytes, buffer.count >= expectedPayloadBytes else { break }
      let payload = Data(buffer.prefix(expectedPayloadBytes))
      buffer.removeFirst(expectedPayloadBytes)
      self.expectedPayloadBytes = nil

      do {
        decoded.append(try JSONDecoder().decode(Value.self, from: payload))
      } catch {
        throw ContainerBuildWorkerFrameError.decodingFailed(error.localizedDescription)
      }
    }
    return decoded
  }

  func finish() throws {
    if let expectedPayloadBytes {
      throw ContainerBuildWorkerFrameError.truncatedPayload(
        expectedBytes: expectedPayloadBytes,
        receivedBytes: buffer.count
      )
    }
    guard buffer.isEmpty else {
      throw ContainerBuildWorkerFrameError.truncatedHeader(receivedBytes: buffer.count)
    }
  }
}
