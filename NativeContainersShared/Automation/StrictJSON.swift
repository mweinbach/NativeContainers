import Foundation

enum StrictJSONError: Error, Equatable, LocalizedError, Sendable {
  case malformed(String)
  case duplicateKey(String)
  case unexpectedKeys(expected: [String], actual: [String])
  case missingKey(String)
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .malformed(let reason):
      "The JSON document is malformed: \(reason)"
    case .duplicateKey(let key):
      "The JSON object contains duplicate key \(key)."
    case .unexpectedKeys(let expected, let actual):
      "The JSON object keys \(actual.sorted()) do not match \(expected.sorted())."
    case .missingKey(let key):
      "The JSON object is missing key \(key)."
    case .invalidValue(let reason):
      "The JSON document contains an invalid value: \(reason)"
    }
  }
}

enum StrictJSONValue: Equatable, Sendable {
  case object([String: StrictJSONValue])
  case array([StrictJSONValue])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  func object(exactKeys: Set<String>) throws -> [String: StrictJSONValue] {
    guard case .object(let object) = self else {
      throw StrictJSONError.invalidValue("an object is required")
    }
    let actual = Set(object.keys)
    guard actual == exactKeys else {
      throw StrictJSONError.unexpectedKeys(
        expected: Array(exactKeys),
        actual: Array(actual)
      )
    }
    return object
  }

  func object(requiredKeys: Set<String>, optionalKeys: Set<String>) throws
    -> [String: StrictJSONValue]
  {
    guard case .object(let object) = self else {
      throw StrictJSONError.invalidValue("an object is required")
    }
    let actual = Set(object.keys)
    guard requiredKeys.isSubset(of: actual),
      actual.isSubset(of: requiredKeys.union(optionalKeys))
    else {
      throw StrictJSONError.unexpectedKeys(
        expected: Array(requiredKeys.union(optionalKeys)),
        actual: Array(actual)
      )
    }
    return object
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var bool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  func integer<T: FixedWidthInteger>(as type: T.Type = T.self) -> T? {
    guard case .number(let value) = self,
      !value.contains("."), !value.contains("e"), !value.contains("E")
    else { return nil }
    return T(value)
  }

  var array: [StrictJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
}

enum StrictJSONDocument {
  static func parse(_ data: Data) throws -> StrictJSONValue {
    var parser = Parser(bytes: Array(data))
    let value = try parser.parseDocument()
    return value
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() throws -> StrictJSONValue {
      skipWhitespace()
      guard index < bytes.count else {
        throw StrictJSONError.malformed("the document is empty")
      }
      let value = try parseValue()
      skipWhitespace()
      guard index == bytes.count else {
        throw StrictJSONError.malformed("unexpected trailing bytes")
      }
      return value
    }

    mutating func parseValue() throws -> StrictJSONValue {
      guard index < bytes.count else {
        throw StrictJSONError.malformed("a value is truncated")
      }
      switch bytes[index] {
      case 0x7b:
        return try parseObject()
      case 0x5b:
        return try parseArray()
      case 0x22:
        return .string(try parseString())
      case 0x74:
        try consumeLiteral("true")
        return .bool(true)
      case 0x66:
        try consumeLiteral("false")
        return .bool(false)
      case 0x6e:
        try consumeLiteral("null")
        return .null
      case 0x2d, 0x30...0x39:
        return .number(try parseNumber())
      default:
        throw StrictJSONError.malformed("an unexpected token begins a value")
      }
    }

    mutating func parseObject() throws -> StrictJSONValue {
      index += 1
      skipWhitespace()
      var object: [String: StrictJSONValue] = [:]
      if consume(0x7d) { return .object(object) }
      while true {
        guard index < bytes.count, bytes[index] == 0x22 else {
          throw StrictJSONError.malformed("an object key must be a string")
        }
        let key = try parseString()
        guard object[key] == nil else { throw StrictJSONError.duplicateKey(key) }
        skipWhitespace()
        guard consume(0x3a) else {
          throw StrictJSONError.malformed("an object key is missing its colon")
        }
        skipWhitespace()
        object[key] = try parseValue()
        skipWhitespace()
        if consume(0x7d) { break }
        guard consume(0x2c) else {
          throw StrictJSONError.malformed("an object member is missing its comma")
        }
        skipWhitespace()
      }
      return .object(object)
    }

    mutating func parseArray() throws -> StrictJSONValue {
      index += 1
      skipWhitespace()
      var array: [StrictJSONValue] = []
      if consume(0x5d) { return .array(array) }
      while true {
        array.append(try parseValue())
        skipWhitespace()
        if consume(0x5d) { break }
        guard consume(0x2c) else {
          throw StrictJSONError.malformed("an array element is missing its comma")
        }
        skipWhitespace()
      }
      return .array(array)
    }

    mutating func parseString() throws -> String {
      let start = index
      index += 1
      var escaped = false
      while index < bytes.count {
        let byte = bytes[index]
        if escaped {
          if byte == 0x75 {
            guard index + 4 < bytes.count,
              bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex)
            else {
              throw StrictJSONError.malformed("a Unicode escape is invalid")
            }
            index += 5
          } else {
            guard [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(byte) else {
              throw StrictJSONError.malformed("a string escape is invalid")
            }
            index += 1
          }
          escaped = false
          continue
        }
        if byte == 0x5c {
          escaped = true
          index += 1
          continue
        }
        if byte == 0x22 {
          index += 1
          let fragment = Data(bytes[start..<index])
          do {
            let value = try JSONSerialization.jsonObject(
              with: fragment,
              options: [.fragmentsAllowed]
            )
            guard let string = value as? String else {
              throw StrictJSONError.malformed("a string could not be decoded")
            }
            return string
          } catch let error as StrictJSONError {
            throw error
          } catch {
            throw StrictJSONError.malformed("a string could not be decoded")
          }
        }
        guard byte >= 0x20 else {
          throw StrictJSONError.malformed("a string contains a control byte")
        }
        index += 1
      }
      throw StrictJSONError.malformed("a string is truncated")
    }

    mutating func parseNumber() throws -> String {
      let start = index
      _ = consume(0x2d)
      guard index < bytes.count else {
        throw StrictJSONError.malformed("a number is truncated")
      }
      if consume(0x30) {
        if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
          throw StrictJSONError.malformed("a number has a leading zero")
        }
      } else {
        guard consumeDigit(0x31...0x39) else {
          throw StrictJSONError.malformed("a number has no integer digits")
        }
        while consumeDigit(0x30...0x39) {}
      }
      if consume(0x2e) {
        guard consumeDigit(0x30...0x39) else {
          throw StrictJSONError.malformed("a number has no fractional digits")
        }
        while consumeDigit(0x30...0x39) {}
      }
      if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
        index += 1
        if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d {
          index += 1
        }
        guard consumeDigit(0x30...0x39) else {
          throw StrictJSONError.malformed("a number has no exponent digits")
        }
        while consumeDigit(0x30...0x39) {}
      }
      guard let number = String(bytes: bytes[start..<index], encoding: .utf8) else {
        throw StrictJSONError.malformed("a number is not UTF-8")
      }
      return number
    }

    mutating func consumeLiteral(_ literal: StaticString) throws {
      let expected = Array(String(describing: literal).utf8)
      guard index + expected.count <= bytes.count,
        bytes[index..<(index + expected.count)].elementsEqual(expected)
      else {
        throw StrictJSONError.malformed("a literal is invalid")
      }
      index += expected.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }

    mutating func consumeDigit(_ range: ClosedRange<UInt8>) -> Bool {
      guard index < bytes.count, range.contains(bytes[index]) else { return false }
      index += 1
      return true
    }

    mutating func skipWhitespace() {
      while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
        index += 1
      }
    }

    static func isHex(_ byte: UInt8) -> Bool {
      (0x30...0x39).contains(byte)
        || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
    }
  }
}

struct CanonicalUUID: Codable, Equatable, Hashable, Sendable {
  let value: UUID

  init(_ value: UUID) { self.value = value }

  init(string: String) throws {
    guard let value = UUID(uuidString: string),
      string == value.uuidString.lowercased()
    else {
      throw StrictJSONError.invalidValue("UUIDs must be lowercase hyphenated strings")
    }
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(string: container.decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.uuidString.lowercased())
  }
}

struct CanonicalBase64: Codable, Equatable, Sendable {
  let data: Data

  init(_ data: Data) { self.data = data }

  init(string: String) throws {
    guard let data = Data(base64Encoded: string),
      data.base64EncodedString() == string
    else {
      throw StrictJSONError.invalidValue("base64 must use canonical padded encoding")
    }
    self.data = data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(string: container.decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(data.base64EncodedString())
  }
}
