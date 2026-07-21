import Foundation

enum NativeContainersControlProtocol {
  static let schemaVersion = 2
  static let minimumTimeoutSeconds = 5
  static let maximumTimeoutSeconds = 3_600
}

enum NativeContainersControlRedactor {
  static func message(_ message: String) -> String {
    let lower = message.lowercased()
    let sensitive = [
      "password", "credential", "secret", "token", "authorization", "proxy",
    ]
    guard !sensitive.contains(where: lower.contains) else {
      return "The operation could not be completed."
    }
    let bounded = String(message.prefix(256))
    guard bounded.unicodeScalars.allSatisfy({ scalar in
      scalar.value >= 0x20 && scalar.value != 0x7f
    }) else {
      return "The operation could not be completed."
    }
    return bounded
  }
}

enum NativeContainersControlOperation: String, Codable, CaseIterable, Sendable {
  case doctor = "linux-box.doctor"
  case imagePrepare = "linux-box.image.prepare"
  case list = "linux-box.list"
  case create = "linux-box.create"
  case status = "linux-box.status"
  case start = "linux-box.start"
  case pause = "linux-box.pause"
  case resume = "linux-box.resume"
  case exec = "linux-box.exec"
  case verify = "linux-box.verify"
  case refresh = "linux-box.refresh"
  case stop = "linux-box.stop"
  case destroy = "linux-box.destroy"
  case smoke = "linux-box.smoke"
}

enum LinuxBoxProfile: String, Codable, CaseIterable, Sendable {
  case standard
  case residential
}

struct LinuxBoxCreatePayload: Codable, Equatable, Sendable {
  let name: String
  let cpuCount: Int
  let memoryBytes: UInt64
  let diskBytes: UInt64
  let profile: LinuxBoxProfile

  init(
    name: String,
    cpuCount: Int,
    memoryBytes: UInt64,
    diskBytes: UInt64,
    profile: LinuxBoxProfile = .standard
  ) {
    self.name = name
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.profile = profile
  }
}

struct LinuxBoxIDPayload: Codable, Equatable, Sendable {
  let id: CanonicalUUID
}

struct LinuxBoxExecPayload: Codable, Equatable, Sendable {
  let id: CanonicalUUID
  let argv: [String]
}

struct LinuxBoxSmokePayload: Codable, Equatable, Sendable {
  let name: String
  let profile: LinuxBoxProfile

  init(name: String, profile: LinuxBoxProfile = .standard) {
    self.name = name
    self.profile = profile
  }
}

enum NativeContainersControlPayload: Equatable, Sendable {
  case empty
  case create(LinuxBoxCreatePayload)
  case id(LinuxBoxIDPayload)
  case exec(LinuxBoxExecPayload)
  case smoke(LinuxBoxSmokePayload)
}

struct NativeContainersControlRequest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let requestID: CanonicalUUID
  let operation: NativeContainersControlOperation
  let timeoutSeconds: Int
  let payload: NativeContainersControlPayload

  init(
    requestID: UUID = UUID(),
    operation: NativeContainersControlOperation,
    timeoutSeconds: Int,
    payload: NativeContainersControlPayload
  ) throws {
    self.schemaVersion = NativeContainersControlProtocol.schemaVersion
    self.requestID = CanonicalUUID(requestID)
    self.operation = operation
    self.timeoutSeconds = timeoutSeconds
    self.payload = payload
    try validate()
  }

  static func decodeStrict(_ data: Data) throws -> Self {
    let root = try StrictJSONDocument.parse(data)
    let object = try root.object(
      exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
    )
    guard object["schemaVersion"]?.integer(as: Int.self)
      == NativeContainersControlProtocol.schemaVersion
    else {
      throw StrictJSONError.invalidValue("the control schema version must be 2")
    }
    guard let requestID = object["requestID"]?.string else {
      throw StrictJSONError.invalidValue("requestID must be a string")
    }
    _ = try CanonicalUUID(string: requestID)
    guard let rawOperation = object["operation"]?.string,
      let operation = NativeContainersControlOperation(rawValue: rawOperation)
    else {
      throw StrictJSONError.invalidValue("the control operation is unknown")
    }
    guard let timeout = object["timeoutSeconds"]?.integer(as: Int.self),
      (NativeContainersControlProtocol.minimumTimeoutSeconds...NativeContainersControlProtocol.maximumTimeoutSeconds)
        .contains(timeout)
    else {
      throw StrictJSONError.invalidValue("timeoutSeconds must be in 5...3600")
    }
    guard let payload = object["payload"] else {
      throw StrictJSONError.missingKey("payload")
    }
    try validatePayloadJSON(payload, for: operation)

    let request: Self
    do {
      request = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw StrictJSONError.invalidValue(error.localizedDescription)
    }
    try request.validate()
    return request
  }

  func validateResponseRequestID(_ responseID: CanonicalUUID) throws {
    guard requestID == responseID else {
      throw StrictJSONError.invalidValue("the response requestID does not match the request")
    }
  }

  func validate() throws {
    guard schemaVersion == NativeContainersControlProtocol.schemaVersion else {
      throw StrictJSONError.invalidValue("the control schema version must be 2")
    }
    guard (NativeContainersControlProtocol.minimumTimeoutSeconds...NativeContainersControlProtocol.maximumTimeoutSeconds)
      .contains(timeoutSeconds)
    else {
      throw StrictJSONError.invalidValue("timeoutSeconds must be in 5...3600")
    }
    switch (operation, payload) {
    case (.doctor, .empty), (.imagePrepare, .empty), (.list, .empty):
      break
    case (.create, .create(let value)):
      try Self.validateName(value.name)
      guard (1...64).contains(value.cpuCount),
        value.memoryBytes >= 1_073_741_824,
        value.diskBytes >= 8 * 1_073_741_824
      else {
        throw StrictJSONError.invalidValue("create resources are out of range")
      }
    case (.status, .id), (.start, .id), (.pause, .id), (.resume, .id),
      (.verify, .id), (.refresh, .id), (.stop, .id), (.destroy, .id):
      break
    case (.exec, .exec(let value)):
      try Self.validateArgv(value.argv)
    case (.smoke, .smoke(let value)):
      try Self.validateName(value.name)
    default:
      throw StrictJSONError.invalidValue("the payload does not match the operation")
    }
  }

  private static func validatePayloadJSON(
    _ payload: StrictJSONValue,
    for operation: NativeContainersControlOperation
  ) throws {
    switch operation {
    case .doctor, .imagePrepare, .list:
      _ = try payload.object(exactKeys: [])
    case .create:
      let object = try payload.object(
        exactKeys: ["name", "cpuCount", "memoryBytes", "diskBytes", "profile"]
      )
      guard let name = object["name"]?.string,
        object["cpuCount"]?.integer(as: Int.self) != nil,
        object["memoryBytes"]?.integer(as: UInt64.self) != nil,
        object["diskBytes"]?.integer(as: UInt64.self) != nil,
        let profile = object["profile"]?.string,
        LinuxBoxProfile(rawValue: profile) != nil
      else { throw StrictJSONError.invalidValue("the create payload is invalid") }
      try validateName(name)
    case .status, .start, .pause, .resume, .verify, .refresh, .stop, .destroy:
      let object = try payload.object(exactKeys: ["id"])
      guard let id = object["id"]?.string else {
        throw StrictJSONError.invalidValue("id must be a string")
      }
      _ = try CanonicalUUID(string: id)
    case .exec:
      let object = try payload.object(exactKeys: ["id", "argv"])
      guard let id = object["id"]?.string, let values = object["argv"]?.array else {
        throw StrictJSONError.invalidValue("the exec payload is invalid")
      }
      _ = try CanonicalUUID(string: id)
      let argv = try values.map { value -> String in
        guard let string = value.string else {
          throw StrictJSONError.invalidValue("argv entries must be strings")
        }
        return string
      }
      try validateArgv(argv)
    case .smoke:
      let object = try payload.object(exactKeys: ["name", "profile"])
      guard let name = object["name"]?.string,
        let profile = object["profile"]?.string,
        LinuxBoxProfile(rawValue: profile) != nil
      else { throw StrictJSONError.invalidValue("the smoke payload is invalid") }
      try validateName(name)
    }
  }

  private static func validateName(_ name: String) throws {
    let bytes = name.utf8
    guard name == name.trimmingCharacters(in: .whitespacesAndNewlines),
      (1...128).contains(bytes.count),
      !bytes.contains(0)
    else {
      throw StrictJSONError.invalidValue("name must be a nonempty bounded canonical string")
    }
  }

  private static func validateArgv(_ argv: [String]) throws {
    guard (1...64).contains(argv.count) else {
      throw StrictJSONError.invalidValue("argv must contain 1...64 entries")
    }
    var total = 0
    for argument in argv {
      let count = argument.utf8.count
      guard (1...4_096).contains(count), !argument.utf8.contains(0) else {
        throw StrictJSONError.invalidValue("argv contains an invalid entry")
      }
      total += count
    }
    guard total <= 32 * 1_024 else {
      throw StrictJSONError.invalidValue("argv exceeds 32 KiB")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, requestID, operation, timeoutSeconds, payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    requestID = try container.decode(CanonicalUUID.self, forKey: .requestID)
    operation = try container.decode(NativeContainersControlOperation.self, forKey: .operation)
    timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
    let payloadDecoder = try container.superDecoder(forKey: .payload)
    switch operation {
    case .doctor, .imagePrepare, .list:
      _ = try EmptyPayload(from: payloadDecoder)
      payload = .empty
    case .create:
      payload = .create(try LinuxBoxCreatePayload(from: payloadDecoder))
    case .status, .start, .pause, .resume, .verify, .refresh, .stop, .destroy:
      payload = .id(try LinuxBoxIDPayload(from: payloadDecoder))
    case .exec:
      payload = .exec(try LinuxBoxExecPayload(from: payloadDecoder))
    case .smoke:
      payload = .smoke(try LinuxBoxSmokePayload(from: payloadDecoder))
    }
  }

  func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(operation, forKey: .operation)
    try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    switch payload {
    case .empty:
      try container.encode(EmptyPayload(), forKey: .payload)
    case .create(let value):
      try container.encode(value, forKey: .payload)
    case .id(let value):
      try container.encode(value, forKey: .payload)
    case .exec(let value):
      try container.encode(value, forKey: .payload)
    case .smoke(let value):
      try container.encode(value, forKey: .payload)
    }
  }
}

private struct EmptyPayload: Codable, Equatable, Sendable {}

enum NativeContainersControlErrorCode: String, Codable, CaseIterable, Sendable {
  case invalidArguments = "invalid_arguments"
  case appUnavailable = "app_unavailable"
  case protocolMismatch = "protocol_mismatch"
  case notFound = "not_found"
  case wrongKind = "wrong_kind"
  case busy
  case invalidState = "invalid_state"
  case imageUnavailable = "image_unavailable"
  case imageIntegrity = "image_integrity"
  case residentialCredentialsRequired = "residential_credentials_required"
  case residentialProxyUnreachable = "residential_proxy_unreachable"
  case proxiedDNSUnavailable = "proxied_dns_unavailable"
  case agentUnavailable = "agent_unavailable"
  case agentIdentityMismatch = "agent_identity_mismatch"
  case guestNotReady = "guest_not_ready"
  case verificationFailed = "verification_failed"
  case securityInvariantFailed = "security_invariant_failed"
  case chromiumSandboxUnavailable = "chromium_sandbox_unavailable"
  case guestExit = "guest_exit"
  case outputLimit = "output_limit"
  case operationTimedOut = "operation_timed_out"
  case cleanupFailed = "cleanup_failed"
  case internalError = "internal_error"
}

struct NativeContainersControlFailure: Codable, Equatable, Sendable {
  let code: NativeContainersControlErrorCode
  let message: String
  let details: LinuxBoxExecResult?

  init(
    code: NativeContainersControlErrorCode,
    message: String,
    details: LinuxBoxExecResult? = nil
  ) {
    self.code = code
    self.message = message
    self.details = details
  }
}

struct NativeContainersControlResponse<DataValue: Codable & Equatable & Sendable>:
  Codable, Equatable, Sendable
{
  let schemaVersion: Int
  let requestID: CanonicalUUID
  let ok: Bool
  let data: DataValue?
  let error: NativeContainersControlFailure?

  init(requestID: UUID, data: DataValue) {
    schemaVersion = NativeContainersControlProtocol.schemaVersion
    self.requestID = CanonicalUUID(requestID)
    ok = true
    self.data = data
    error = nil
  }

  init(requestID: UUID, error: NativeContainersControlFailure) {
    schemaVersion = NativeContainersControlProtocol.schemaVersion
    self.requestID = CanonicalUUID(requestID)
    ok = false
    data = nil
    self.error = error
  }

  func validate(expectedRequestID: CanonicalUUID) throws {
    guard schemaVersion == NativeContainersControlProtocol.schemaVersion,
      requestID == expectedRequestID,
      (ok && data != nil && error == nil) || (!ok && data == nil && error != nil)
    else {
      throw StrictJSONError.invalidValue("the control response envelope is invalid")
    }
  }
}

enum LinuxBoxState: String, Codable, CaseIterable, Sendable {
  case stopped, starting, running, paused, stopping, failed
}

struct LinuxBoxSummary: Codable, Equatable, Sendable {
  let id: CanonicalUUID
  let name: String
  let state: LinuxBoxState
  let ready: Bool
  let imageID: String
  let agentProtocol: Int
  let cpuCount: Int
  let memoryBytes: UInt64
  let diskBytes: UInt64
  let profile: LinuxBoxProfile

  init(
    id: CanonicalUUID, name: String, state: LinuxBoxState, ready: Bool,
    imageID: String, agentProtocol: Int, cpuCount: Int, memoryBytes: UInt64,
    diskBytes: UInt64, profile: LinuxBoxProfile = .standard
  ) {
    self.id = id; self.name = name; self.state = state; self.ready = ready
    self.imageID = imageID; self.agentProtocol = agentProtocol
    self.cpuCount = cpuCount; self.memoryBytes = memoryBytes; self.diskBytes = diskBytes
    self.profile = profile
  }
}

struct LinuxBoxCheck: Codable, Equatable, Sendable {
  let name: String
  let ok: Bool
  let code: String?
  let details: String?
}

struct LinuxBoxVerificationCheck: Codable, Equatable, Sendable {
  let name: String
  let ok: Bool
  let details: String?
}

struct LinuxBoxVerification: Codable, Equatable, Sendable {
  struct Egress: Codable, Equatable, Sendable {
    let hostDirectIP: String
    let hostProxyIP: String
    let curlIP: String
    let chromiumIP: String
    let isp: String
    let country: String
  }

  struct DoH: Codable, Equatable, Sendable {
    let address: String
    let serverName: String
  }
  let verifiedAt: Date
  let profile: LinuxBoxProfile
  let egress: Egress?
  let doh: DoH?
  let checks: [LinuxBoxVerificationCheck]

  init(
    verifiedAt: Date,
    profile: LinuxBoxProfile = .standard,
    egress: Egress? = nil,
    doh: DoH? = nil,
    checks: [LinuxBoxVerificationCheck]
  ) {
    self.verifiedAt = verifiedAt; self.profile = profile
    self.egress = egress; self.doh = doh; self.checks = checks
  }
}

struct LinuxBoxDoctorResult: Codable, Equatable, Sendable { let checks: [LinuxBoxCheck] }
struct LinuxBoxImagePrepareResult: Codable, Equatable, Sendable {
  let imageID: String
  let cached: Bool
  let compressedSHA256: String
  let rawSHA512: String
}
struct LinuxBoxListResult: Codable, Equatable, Sendable { let boxes: [LinuxBoxSummary] }
struct LinuxBoxChangedResult: Codable, Equatable, Sendable {
  let box: LinuxBoxSummary
  let changed: Bool
}
struct LinuxBoxVerifiedResult: Codable, Equatable, Sendable {
  let box: LinuxBoxSummary
  let verification: LinuxBoxVerification
}
struct LinuxBoxDestroyResult: Codable, Equatable, Sendable {
  let id: CanonicalUUID
  let state: String
  let changed: Bool
}
struct LinuxBoxExecResult: Codable, Equatable, Sendable {
  let id: CanonicalUUID
  let exitCode: Int32
  let stdoutBase64: CanonicalBase64
  let stderrBase64: CanonicalBase64
}
struct LinuxBoxSmokeResult: Codable, Equatable, Sendable {
  let id: CanonicalUUID
  let state: String
  let verification: LinuxBoxVerification
  let cleanup: [LinuxBoxCheck]
}
