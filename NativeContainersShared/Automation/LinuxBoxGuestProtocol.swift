import Darwin
import Foundation
enum LinuxBoxGuestProtocolError: Error {
  case invalidProfileCombination
  case invalidPayload
}

enum LinuxBoxGuestProtocol {
  static let schemaVersion = 2
  static let socketPort: UInt32 = 4050
  static let minimumTimeoutSeconds = 1
  static let maximumTimeoutSeconds = 3_600
  static let challengeBytes = 32
  static let maximumOutputBytes = 256 * 1_024
}


enum LinuxBoxGuestOperation: String, Codable, CaseIterable, Sendable {
  case hello, configure, ping, status, exec, verify, quiesce, shutdown
}

enum LinuxBoxGuestState: String, Codable, CaseIterable, Sendable {
  case awaitingConfiguration
  case authorizing
  case healthy
  case verifying
  case ready
  case quiescing
  case quiesced
  case failed
}

enum LinuxBoxGuestErrorCode: String, Codable, CaseIterable, Sendable {
  case invalidRequest = "invalid_request"
  case protocolMismatch = "protocol_mismatch"
  case invalidState = "invalid_state"
  case busy
  case configurationInvalid = "configuration_invalid"
  case notReady = "not_ready"
  case execFailed = "exec_failed"
  case outputLimit = "output_limit"
  case operationTimedOut = "operation_timed_out"
  case internalError = "internal_error"
}

struct LinuxBoxGuestResidentialCredentials: Codable, Equatable, Sendable {
  let schema: Int
  let provider: String
  let product: String
  let scheme: String
  let host: String
  let port: Int
  let username: String
  let password: String
}

struct LinuxBoxGuestDoHEndpoint: Codable, Equatable, Sendable {
  let address: String
  let port: Int
  let serverName: String
  let path: String

  private enum CodingKeys: String, CodingKey {
    case address, port, path
    case serverName = "server_name"
  }
}

struct LinuxBoxGuestResidentialEndpoints: Codable, Equatable, Sendable {
  let schema: Int
  let host: String
  let port: Int
  let selected: String
  let allowed: [String]
  let doh: LinuxBoxGuestDoHEndpoint
  let resolvedAt: String

  private enum CodingKeys: String, CodingKey {
    case schema, host, port, selected, allowed, doh
    case resolvedAt = "resolved_at"
  }
}

struct LinuxBoxGuestResidentialConfiguration: Codable, Equatable, Sendable {
  let schema: Int
  let credentials: LinuxBoxGuestResidentialCredentials
  let endpoints: LinuxBoxGuestResidentialEndpoints
}

struct LinuxBoxGuestHelloPayload: Codable, Equatable, Sendable {
  let challenge: CanonicalBase64
}


struct LinuxBoxGuestConfigurePayload: Codable, Equatable, Sendable {
  let profile: LinuxBoxProfile
  let configuration: LinuxBoxGuestResidentialConfiguration?
  let expectedProxyIP: String?

  init(
    profile: LinuxBoxProfile,
    configuration: LinuxBoxGuestResidentialConfiguration? = nil,
    expectedProxyIP: String? = nil
  ) throws {
    guard profile == .residential
      ? configuration != nil && expectedProxyIP != nil
      : configuration == nil && expectedProxyIP == nil
    else { throw LinuxBoxGuestProtocolError.invalidProfileCombination }
    self.profile = profile
    self.configuration = configuration
    self.expectedProxyIP = expectedProxyIP
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(c.allKeys) == Set(CodingKeys.allCases) || Set(c.allKeys) == [.profile]
      || Set(c.allKeys) == [.profile, .configuration, .expectedProxyIP]
    else { throw LinuxBoxGuestProtocolError.invalidPayload }
    try self.init(
      profile: c.decode(LinuxBoxProfile.self, forKey: .profile),
      configuration: c.decodeIfPresent(LinuxBoxGuestResidentialConfiguration.self, forKey: .configuration),
      expectedProxyIP: c.decodeIfPresent(String.self, forKey: .expectedProxyIP)
    )
  }
  private enum CodingKeys: String, CodingKey, CaseIterable { case profile, configuration, expectedProxyIP }
}
struct LinuxBoxGuestPingPayload: Codable, Equatable, Sendable { let sequence: UInt64 }
struct LinuxBoxGuestExecPayload: Codable, Equatable, Sendable {
  let argv: [String]
  let timeoutSeconds: Int
}
struct LinuxBoxGuestVerifyPayload: Codable, Equatable, Sendable {
  let profile: LinuxBoxProfile
  let expectedProxyIP: String?
  let hostDirectIP: String?

  init(profile: LinuxBoxProfile, expectedProxyIP: String? = nil, hostDirectIP: String? = nil) throws {
    guard profile == .residential
      ? expectedProxyIP != nil && hostDirectIP != nil
      : expectedProxyIP == nil && hostDirectIP == nil
    else { throw LinuxBoxGuestProtocolError.invalidProfileCombination }
    self.profile = profile
    self.expectedProxyIP = expectedProxyIP
    self.hostDirectIP = hostDirectIP
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      profile: c.decode(LinuxBoxProfile.self, forKey: .profile),
      expectedProxyIP: c.decodeIfPresent(String.self, forKey: .expectedProxyIP),
      hostDirectIP: c.decodeIfPresent(String.self, forKey: .hostDirectIP)
    )
  }
  private enum CodingKeys: String, CodingKey { case profile, expectedProxyIP, hostDirectIP }
}
enum LinuxBoxGuestQuiesceReason: String, Codable, CaseIterable, Sendable {
  case pause, refresh, stop
  case controlLoss = "control_loss"
  case shutdown
}
struct LinuxBoxGuestQuiescePayload: Codable, Equatable, Sendable {
  let reason: LinuxBoxGuestQuiesceReason
}

enum LinuxBoxGuestPayload: Equatable, Sendable {
  case hello(LinuxBoxGuestHelloPayload)
  case configure(LinuxBoxGuestConfigurePayload)
  case ping(LinuxBoxGuestPingPayload)
  case status
  case exec(LinuxBoxGuestExecPayload)
  case verify(LinuxBoxGuestVerifyPayload)
  case quiesce(LinuxBoxGuestQuiescePayload)
  case shutdown
}

struct LinuxBoxGuestRequest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let requestID: CanonicalUUID
  let operation: LinuxBoxGuestOperation
  let timeoutSeconds: Int
  let payload: LinuxBoxGuestPayload

  init(
    requestID: UUID = UUID(),
    operation: LinuxBoxGuestOperation,
    timeoutSeconds: Int,
    payload: LinuxBoxGuestPayload
  ) throws {
    schemaVersion = LinuxBoxGuestProtocol.schemaVersion
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
      == LinuxBoxGuestProtocol.schemaVersion
    else { throw StrictJSONError.invalidValue("the guest schema version must be 2") }
    guard let requestID = object["requestID"]?.string else {
      throw StrictJSONError.invalidValue("requestID must be a string")
    }
    _ = try CanonicalUUID(string: requestID)
    guard let rawOperation = object["operation"]?.string,
      let operation = LinuxBoxGuestOperation(rawValue: rawOperation)
    else { throw StrictJSONError.invalidValue("the guest operation is unknown") }
    guard let timeout = object["timeoutSeconds"]?.integer(as: Int.self),
      (LinuxBoxGuestProtocol.minimumTimeoutSeconds...LinuxBoxGuestProtocol.maximumTimeoutSeconds)
        .contains(timeout)
    else { throw StrictJSONError.invalidValue("timeoutSeconds must be in 1...3600") }
    guard let payload = object["payload"] else { throw StrictJSONError.missingKey("payload") }
    try validatePayloadJSON(payload, operation: operation)
    do {
      let request = try JSONDecoder().decode(Self.self, from: data)
      try request.validate()
      return request
    } catch let error as StrictJSONError {
      throw error
    } catch {
      throw StrictJSONError.invalidValue(error.localizedDescription)
    }
  }

  func validate() throws {
    guard schemaVersion == LinuxBoxGuestProtocol.schemaVersion else {
      throw StrictJSONError.invalidValue("the guest schema version must be 2")
    }
    guard (LinuxBoxGuestProtocol.minimumTimeoutSeconds...LinuxBoxGuestProtocol.maximumTimeoutSeconds).contains(timeoutSeconds)
    else { throw StrictJSONError.invalidValue("timeoutSeconds must be in 1...3600") }
    switch (operation, payload) {
    case (.hello, .hello(let value)):
      guard value.challenge.data.count == LinuxBoxGuestProtocol.challengeBytes else { throw StrictJSONError.invalidValue("hello challenge must contain 32 bytes") }
    case (.configure, .configure(let value)):
      if value.profile == .residential {
        guard let configuration = value.configuration, let expectedProxyIP = value.expectedProxyIP else { throw LinuxBoxGuestProtocolError.invalidProfileCombination }
        try Self.validateConfiguration(configuration)
        try Self.validateIPv4(expectedProxyIP, name: "expectedProxyIP")
      }
    case (.ping, .ping), (.status, .status), (.shutdown, .shutdown), (.quiesce, .quiesce):
      break
    case (.exec, .exec(let value)):
      guard (1...LinuxBoxGuestProtocol.maximumTimeoutSeconds).contains(value.timeoutSeconds) else { throw StrictJSONError.invalidValue("exec timeoutSeconds must be in 1...3600") }
      try Self.validateArgv(value.argv)
    case (.verify, .verify(let value)):
      if value.profile == .residential {
        guard let expectedProxyIP = value.expectedProxyIP, let hostDirectIP = value.hostDirectIP else { throw LinuxBoxGuestProtocolError.invalidProfileCombination }
        try Self.validateIPv4(expectedProxyIP, name: "expectedProxyIP")
        try Self.validateIPv4(hostDirectIP, name: "hostDirectIP")
      }
    default:
      throw StrictJSONError.invalidValue("the payload does not match the guest operation")
    }
  }

  private static func validatePayloadJSON(
    _ payload: StrictJSONValue,
    operation: LinuxBoxGuestOperation
  ) throws {
    switch operation {
    case .hello:
      let object = try payload.object(exactKeys: ["challenge"])
      guard let value = object["challenge"]?.string else {
        throw StrictJSONError.invalidValue("challenge must be a string")
      }
      let challenge = try CanonicalBase64(string: value)
    case .configure:
      let object: [String: StrictJSONValue]
      do { object = try payload.object(exactKeys: ["profile"]) }
      catch { object = try payload.object(exactKeys: ["profile", "configuration", "expectedProxyIP"]) }
      if object["profile"]?.string == LinuxBoxProfile.standard.rawValue { return }
      guard let configuration = object["configuration"], object["expectedProxyIP"]?.string != nil else {
        throw StrictJSONError.invalidValue("the configure payload is invalid")
      }
      let configurationObject = try configuration.object(exactKeys: ["schema", "credentials", "endpoints"])
      guard configurationObject["schema"]?.integer(as: Int.self) != nil else { throw StrictJSONError.invalidValue("the residential schema is invalid") }
      let credentials = try configurationObject["credentials"]!.object(exactKeys: ["schema", "provider", "product", "scheme", "host", "port", "username", "password"])
      guard credentials["schema"]?.integer(as: Int.self) != nil, credentials["provider"]?.string != nil, credentials["product"]?.string != nil, credentials["scheme"]?.string != nil, credentials["host"]?.string != nil, credentials["port"]?.integer(as: Int.self) != nil, credentials["username"]?.string != nil, credentials["password"]?.string != nil else { throw StrictJSONError.invalidValue("the credential configuration is invalid") }
      let endpoints = try configurationObject["endpoints"]!.object(exactKeys: ["schema", "host", "port", "selected", "allowed", "doh", "resolved_at"])
      guard endpoints["schema"]?.integer(as: Int.self) != nil, endpoints["host"]?.string != nil, endpoints["port"]?.integer(as: Int.self) != nil, endpoints["selected"]?.string != nil, endpoints["allowed"]?.array != nil, endpoints["resolved_at"]?.string != nil else { throw StrictJSONError.invalidValue("the endpoint configuration is invalid") }
      let doh = try endpoints["doh"]!.object(exactKeys: ["address", "port", "server_name", "path"])
      guard doh["address"]?.string != nil, doh["port"]?.integer(as: Int.self) != nil, doh["server_name"]?.string != nil, doh["path"]?.string != nil else { throw StrictJSONError.invalidValue("the DoH configuration is invalid") }
    case .ping:
      let object = try payload.object(exactKeys: ["sequence"])
      guard object["sequence"]?.integer(as: UInt64.self) != nil else {
        throw StrictJSONError.invalidValue("sequence must be an unsigned integer")
      }
    case .status, .shutdown:
      _ = try payload.object(exactKeys: [])
    case .exec:
      let object = try payload.object(exactKeys: ["argv", "timeoutSeconds"])
      guard let values = object["argv"]?.array,
        object["timeoutSeconds"]?.integer(as: Int.self) != nil
      else { throw StrictJSONError.invalidValue("the exec payload is invalid") }
      try validateArgv(try values.map {
        guard let value = $0.string else {
          throw StrictJSONError.invalidValue("argv entries must be strings")
        }
        return value
      })
    case .verify:
      let object: [String: StrictJSONValue]
      do { object = try payload.object(exactKeys: ["profile"]) }
      catch { object = try payload.object(exactKeys: ["profile", "expectedProxyIP", "hostDirectIP"]) }
      if object["profile"]?.string == LinuxBoxProfile.standard.rawValue { return }
      guard object["expectedProxyIP"]?.string != nil, object["hostDirectIP"]?.string != nil else {
        throw StrictJSONError.invalidValue("the verify payload is invalid")
      }
    case .quiesce:
      let object = try payload.object(exactKeys: ["reason"])
      guard let value = object["reason"]?.string,
        LinuxBoxGuestQuiesceReason(rawValue: value) != nil
      else { throw StrictJSONError.invalidValue("the quiesce reason is invalid") }
    }
  }

  private static func validateConfiguration(
    _ configuration: LinuxBoxGuestResidentialConfiguration
  ) throws {
    let credentials = configuration.credentials
    guard configuration.schema == 1,
      credentials.schema == 1,
      credentials.provider == "decodo",
      credentials.product == "residential",
      credentials.scheme == "socks5",
      credentials.host == "gate.decodo.com",
      credentials.port == 7_000,
      (47...4_096).contains(credentials.username.utf8.count),
      (1...4_096).contains(credentials.password.utf8.count),
      credentials.username.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
      credentials.password.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
      !credentials.username.contains(":")
    else { throw StrictJSONError.invalidValue("the residential credential is invalid") }

    let endpoints = configuration.endpoints
    guard endpoints.schema == 1,
      endpoints.host == "gate.decodo.com",
      endpoints.port == 7_000,
      !endpoints.allowed.isEmpty,
      Set(endpoints.allowed).count == endpoints.allowed.count
    else { throw StrictJSONError.invalidValue("the residential endpoints are invalid") }
    for address in endpoints.allowed {
      try validateIPv4(address, name: "endpoints.allowed")
    }
    guard endpoints.allowed.sorted(by: {
      Self.ipv4Integer($0) < Self.ipv4Integer($1)
    })
      == endpoints.allowed,
      endpoints.allowed.contains(endpoints.selected)
    else { throw StrictJSONError.invalidValue("the endpoint list is not canonical") }
    try validateIPv4(endpoints.selected, name: "endpoints.selected")
    try validateIPv4(endpoints.doh.address, name: "doh.address")
    guard endpoints.doh.port == 443,
      ["cloudflare-dns.com", "dns.google"].contains(endpoints.doh.serverName),
      endpoints.doh.path == "/dns-query",
      ISO8601DateFormatter().date(from: endpoints.resolvedAt) != nil
    else { throw StrictJSONError.invalidValue("the DoH endpoint is invalid") }
  }

  private static func ipv4Integer(_ value: String) -> UInt32 {
    var address = in_addr()
    let parsed = value.withCString { inet_pton(AF_INET, $0, &address) }
    precondition(parsed == 1)
    return UInt32(bigEndian: address.s_addr)
  }

  private static func validateIPv4(_ value: String, name: String) throws {
    var address = in_addr()
    guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1,
      value.split(separator: ".").count == 4
    else { throw StrictJSONError.invalidValue("\(name) must be canonical IPv4") }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
      String(cString: buffer) == value
    else { throw StrictJSONError.invalidValue("\(name) must be canonical IPv4") }
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
    guard total <= 32 * 1_024 else { throw StrictJSONError.invalidValue("argv exceeds 32 KiB") }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, requestID, operation, timeoutSeconds, payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    requestID = try container.decode(CanonicalUUID.self, forKey: .requestID)
    operation = try container.decode(LinuxBoxGuestOperation.self, forKey: .operation)
    timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
    let payloadDecoder = try container.superDecoder(forKey: .payload)
    switch operation {
    case .hello: payload = .hello(try LinuxBoxGuestHelloPayload(from: payloadDecoder))
    case .configure: payload = .configure(try LinuxBoxGuestConfigurePayload(from: payloadDecoder))
    case .ping: payload = .ping(try LinuxBoxGuestPingPayload(from: payloadDecoder))
    case .status:
      _ = try LinuxBoxGuestEmptyPayload(from: payloadDecoder)
      payload = .status
    case .exec: payload = .exec(try LinuxBoxGuestExecPayload(from: payloadDecoder))
    case .verify: payload = .verify(try LinuxBoxGuestVerifyPayload(from: payloadDecoder))
    case .quiesce: payload = .quiesce(try LinuxBoxGuestQuiescePayload(from: payloadDecoder))
    case .shutdown:
      _ = try LinuxBoxGuestEmptyPayload(from: payloadDecoder)
      payload = .shutdown
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
    case .hello(let value): try container.encode(value, forKey: .payload)
    case .configure(let value): try container.encode(value, forKey: .payload)
    case .ping(let value): try container.encode(value, forKey: .payload)
    case .status: try container.encode(LinuxBoxGuestEmptyPayload(), forKey: .payload)
    case .exec(let value): try container.encode(value, forKey: .payload)
    case .verify(let value): try container.encode(value, forKey: .payload)
    case .quiesce(let value): try container.encode(value, forKey: .payload)
    case .shutdown: try container.encode(LinuxBoxGuestEmptyPayload(), forKey: .payload)
    }
  }
}

private struct LinuxBoxGuestEmptyPayload: Codable, Equatable, Sendable {}

struct LinuxBoxGuestError: Codable, Equatable, Sendable {
  let code: LinuxBoxGuestErrorCode
  let message: String
  let details: LinuxBoxGuestExecResult?
}

struct LinuxBoxGuestResponse<DataValue: Codable & Equatable & Sendable>:
  Codable, Equatable, Sendable
{
  let schemaVersion: Int
  let requestID: CanonicalUUID
  let ok: Bool
  let data: DataValue?
  let error: LinuxBoxGuestError?

  init(requestID: UUID, data: DataValue) {
    schemaVersion = LinuxBoxGuestProtocol.schemaVersion
    self.requestID = CanonicalUUID(requestID)
    ok = true
    self.data = data
    error = nil
  }

  init(requestID: UUID, error: LinuxBoxGuestError) {
    schemaVersion = LinuxBoxGuestProtocol.schemaVersion
    self.requestID = CanonicalUUID(requestID)
    ok = false
    data = nil
    self.error = error
  }
}

struct LinuxBoxGuestHelloResult: Codable, Equatable, Sendable {
  let challenge: CanonicalBase64
  let `protocol`: Int
  let imageID: String
  let imageBuildRevision: String
  let bootID: CanonicalUUID
  let state: LinuxBoxGuestState
}
struct LinuxBoxGuestConfigureResult: Codable, Equatable, Sendable {
  let profile: LinuxBoxProfile
  let state: LinuxBoxGuestState
  let uplink: String
  let authorizationPublished: Bool
}
struct LinuxBoxGuestPingResult: Codable, Equatable, Sendable {
  let sequence: UInt64
  let bootID: CanonicalUUID
  let state: LinuxBoxGuestState
}
struct LinuxBoxGuestStatusResult: Codable, Equatable, Sendable {
  let profile: LinuxBoxProfile?
  let state: LinuxBoxGuestState
  let bootID: CanonicalUUID
  let uplink: String?
  let authorizationActive: Bool
  let networkdActive: Bool
  let singBoxActive: Bool
  let baselineActive: Bool
  let ready: Bool
  let activeOperation: LinuxBoxGuestOperation?
  init(
    profile: LinuxBoxProfile?,
    state: LinuxBoxGuestState,
    bootID: CanonicalUUID,
    uplink: String?,
    authorizationActive: Bool,
    networkdActive: Bool,
    singBoxActive: Bool,
    baselineActive: Bool,
    ready: Bool,
    activeOperation: LinuxBoxGuestOperation?
  ) {
    self.profile = profile
    self.state = state
    self.bootID = bootID
    self.uplink = uplink
    self.authorizationActive = authorizationActive
    self.networkdActive = networkdActive
    self.singBoxActive = singBoxActive
    self.baselineActive = baselineActive
    self.ready = ready
    self.activeOperation = activeOperation
  }


  private enum CodingKeys: String, CodingKey, CaseIterable {
    case profile, state, bootID, uplink, authorizationActive, networkdActive
    case singBoxActive, baselineActive, ready, activeOperation
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
      throw LinuxBoxGuestProtocolError.invalidPayload
    }
    profile = try container.decodeIfPresent(LinuxBoxProfile.self, forKey: .profile)
    state = try container.decode(LinuxBoxGuestState.self, forKey: .state)
    bootID = try container.decode(CanonicalUUID.self, forKey: .bootID)
    uplink = try container.decodeIfPresent(String.self, forKey: .uplink)
    authorizationActive = try container.decode(Bool.self, forKey: .authorizationActive)
    networkdActive = try container.decode(Bool.self, forKey: .networkdActive)
    singBoxActive = try container.decode(Bool.self, forKey: .singBoxActive)
    baselineActive = try container.decode(Bool.self, forKey: .baselineActive)
    ready = try container.decode(Bool.self, forKey: .ready)
    activeOperation = try container.decodeIfPresent(
      LinuxBoxGuestOperation.self,
      forKey: .activeOperation
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profile, forKey: .profile)
    try container.encode(state, forKey: .state)
    try container.encode(bootID, forKey: .bootID)
    try container.encode(uplink, forKey: .uplink)
    try container.encode(authorizationActive, forKey: .authorizationActive)
    try container.encode(networkdActive, forKey: .networkdActive)
    try container.encode(singBoxActive, forKey: .singBoxActive)
    try container.encode(baselineActive, forKey: .baselineActive)
    try container.encode(ready, forKey: .ready)
    try container.encode(activeOperation, forKey: .activeOperation)
  }
}
struct LinuxBoxGuestExecResult: Codable, Equatable, Sendable {
  let exitCode: Int32
  let stdoutBase64: CanonicalBase64
  let stderrBase64: CanonicalBase64
}
struct LinuxBoxGuestVerificationCheck: Codable, Equatable, Sendable {
  let name: String
  let ok: Bool
  let details: String?
}
struct LinuxBoxGuestVerifyResult: Codable, Equatable, Sendable {
  struct Egress: Codable, Equatable, Sendable {
    let curlIP: String
    let chromiumIP: String
    let isp: String
    let country: String
  }
  struct DoH: Codable, Equatable, Sendable {
    let address: String
    let serverName: String
  }
  let egress: Egress?
  let doh: DoH?
  let checks: [LinuxBoxGuestVerificationCheck]
}
struct LinuxBoxGuestQuiesceResult: Codable, Equatable, Sendable {
  let state: LinuxBoxGuestState
  let singBoxStopped: Bool
  let networkClientsStopped: Bool
  let runtimeSecretsRemoved: Bool
  let baselineActive: Bool
}
struct LinuxBoxGuestShutdownResult: Codable, Equatable, Sendable { let accepted: Bool }
