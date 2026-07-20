import Foundation
import Security

actor LinuxVirtualMachineAgentClient {
  typealias FailureHandler = @Sendable (any Error) async -> Void

  private struct PendingResponse {
    let continuation: CheckedContinuation<Data, any Error>
    let timeoutTask: Task<Void, Never>
  }

  private let transport: any LinuxVirtualMachineAgentTransport
  private var readerTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var pending: [UUID: PendingResponse] = [:]
  private var bootID: UUID?
  private var heartbeatSequence: UInt64 = 0
  private var closed = false
  private var failureHandler: FailureHandler?

  init(transport: any LinuxVirtualMachineAgentTransport) {
    self.transport = transport
  }

  deinit {
    readerTask?.cancel()
    heartbeatTask?.cancel()
    transport.close()
  }

  func setFailureHandler(_ handler: @escaping FailureHandler) {
    failureHandler = handler
  }

  func establish(
    descriptor: LinuxBoxDescriptor,
    timeoutSeconds: Int = 60
  ) async throws -> LinuxBoxGuestStatusResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
    guard bootID == nil else {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "hello was already completed"
      )
    }
    var challenge = Data(count: LinuxBoxGuestProtocol.challengeBytes)
    let randomStatus = challenge.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw LinuxVirtualMachineAgentClientError.identityMismatch
    }
    let hello: LinuxBoxGuestHelloResult = try await request(
      operation: .hello,
      timeoutSeconds: timeoutSeconds,
      payload: .hello(LinuxBoxGuestHelloPayload(challenge: CanonicalBase64(challenge)))
    )
    guard hello.challenge.data == challenge,
      hello.protocol == descriptor.guestAgentProtocolVersion,
      hello.imageID == descriptor.imageID,
      hello.imageBuildRevision == descriptor.imageBuildRevision
    else {
      throw LinuxVirtualMachineAgentClientError.identityMismatch
    }
    bootID = hello.bootID.value
    startHeartbeat()
    let current = try await status(
      timeoutSeconds: try Self.remainingSeconds(until: deadline, clock: clock)
    )
    guard current.baselineActive else {
      throw LinuxVirtualMachineAgentClientError.securityInvariant(
        "the baseline firewall is inactive"
      )
    }
    return current
  }

  private static func remainingSeconds(
    until deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> Int {
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw LinuxVirtualMachineAgentClientError.timedOut
    }
    let components = remaining.components
    let rounded = components.seconds + (components.attoseconds > 0 ? 1 : 0)
    guard rounded > 0 else {
      throw LinuxVirtualMachineAgentClientError.timedOut
    }
    return Int(rounded)
  }

  func status(timeoutSeconds: Int = 30) async throws -> LinuxBoxGuestStatusResult {
    let result: LinuxBoxGuestStatusResult = try await request(
      operation: .status,
      timeoutSeconds: timeoutSeconds,
      payload: .status
    )
    try requirePinnedBootID(result.bootID.value)
    return result
  }

  func configure(
    profile: LinuxBoxProfile,
    configuration: LinuxBoxGuestResidentialConfiguration? = nil,
    expectedProxyIP: String? = nil,
    timeoutSeconds: Int
  ) async throws -> LinuxBoxGuestConfigureResult {
    try await request(
      operation: .configure,
      timeoutSeconds: timeoutSeconds,
      payload: .configure(
        try LinuxBoxGuestConfigurePayload(
          profile: profile,
          configuration: configuration,
          expectedProxyIP: expectedProxyIP
        )
      )
    )
  }

  func verify(
    profile: LinuxBoxProfile,
    expectedProxyIP: String? = nil,
    hostDirectIP: String? = nil,
    timeoutSeconds: Int
  ) async throws -> LinuxBoxGuestVerifyResult {
    try await request(
      operation: .verify,
      timeoutSeconds: timeoutSeconds,
      payload: .verify(
        try LinuxBoxGuestVerifyPayload(
          profile: profile,
          expectedProxyIP: expectedProxyIP,
          hostDirectIP: hostDirectIP
        )
      )
    )
  }

  func execute(
    argv: [String],
    timeoutSeconds: Int
  ) async throws -> LinuxBoxGuestExecResult {
    try await request(
      operation: .exec,
      timeoutSeconds: timeoutSeconds,
      payload: .exec(
        LinuxBoxGuestExecPayload(
          argv: argv,
          timeoutSeconds: timeoutSeconds
        )
      )
    )
  }

  func quiesce(
    reason: LinuxBoxGuestQuiesceReason,
    timeoutSeconds: Int = 30
  ) async throws -> LinuxBoxGuestQuiesceResult {
    try await request(
      operation: .quiesce,
      timeoutSeconds: timeoutSeconds,
      payload: .quiesce(LinuxBoxGuestQuiescePayload(reason: reason))
    )
  }

  func shutdown(timeoutSeconds: Int = 30) async throws -> LinuxBoxGuestShutdownResult {
    try await request(
      operation: .shutdown,
      timeoutSeconds: timeoutSeconds,
      payload: .shutdown
    )
  }

  func close() {
    guard !closed else { return }
    closed = true
    readerTask?.cancel()
    heartbeatTask?.cancel()
    transport.close()
    failPending(with: LinuxVirtualMachineAgentClientError.connectionClosed)
  }

  private func request<Response: Codable & Equatable & Sendable>(
    operation: LinuxBoxGuestOperation,
    timeoutSeconds: Int,
    payload: LinuxBoxGuestPayload
  ) async throws -> Response {
    guard !closed else {
      throw LinuxVirtualMachineAgentClientError.connectionClosed
    }
    let request = try LinuxBoxGuestRequest(
      operation: operation,
      timeoutSeconds: timeoutSeconds,
      payload: payload
    )
    let requestID = request.requestID.value
    let frame = try BoundedJSONFrameCodec.encode(request)
    ensureReader()

    let responseData = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        let timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(timeoutSeconds))
          guard !Task.isCancelled else { return }
          await self?.expire(requestID)
        }
        pending[requestID] = PendingResponse(
          continuation: continuation,
          timeoutTask: timeoutTask
        )
        let transport = transport
        Task { [weak self] in
          do {
            try await transport.writeFrame(
              frame,
              timeout: .seconds(timeoutSeconds)
            )
          } catch {
            await self?.connectionFailed(error)
          }
        }
      }
    } onCancel: {
      Task { await self.connectionFailed(CancellationError()) }
    }

    try Self.validateResponseData(
      responseData,
      expectedRequestID: requestID,
      operation: operation
    )
    let response: LinuxBoxGuestResponse<Response>
    do {
      response = try JSONDecoder().decode(
        LinuxBoxGuestResponse<Response>.self,
        from: responseData
      )
    } catch {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "the guest response could not be decoded"
      )
    }
    guard response.schemaVersion == LinuxBoxGuestProtocol.schemaVersion,
      response.requestID.value == requestID
    else {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "the guest response identity did not match"
      )
    }
    if response.ok, let data = response.data, response.error == nil {
      return data
    }
    if !response.ok, response.data == nil, let error = response.error,
      error.message.utf8.count <= 512
    {
      throw LinuxVirtualMachineAgentClientError.guest(
        code: error.code,
        message: error.message,
        details: error.details
      )
    }
    throw LinuxVirtualMachineAgentClientError.protocolViolation(
      "the guest response success shape is invalid"
    )
  }

  private func ensureReader() {
    guard readerTask == nil else { return }
    readerTask = Task { [weak self] in
      guard let self else { return }
      await self.readResponses()
    }
  }

  private func readResponses() async {
    do {
      while !Task.isCancelled {
        let payload = try await transport.readFrame(timeout: .seconds(65))
        let requestID = try Self.responseRequestID(payload)
        guard let response = pending.removeValue(forKey: requestID) else {
          throw LinuxVirtualMachineAgentClientError.protocolViolation(
            "the guest sent an unknown or duplicate request ID"
          )
        }
        response.timeoutTask.cancel()
        response.continuation.resume(returning: payload)
      }
    } catch {
      await connectionFailed(error)
    }
  }

  private func startHeartbeat() {
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(10))
          guard let self else { return }
          try await self.sendHeartbeat()
        } catch is CancellationError {
          return
        } catch {
          guard let self else { return }
          await self.connectionFailed(error)
          return
        }
      }
    }
  }

  private func sendHeartbeat() async throws {
    heartbeatSequence &+= 1
    let expected = heartbeatSequence
    let result: LinuxBoxGuestPingResult = try await request(
      operation: .ping,
      timeoutSeconds: 20,
      payload: .ping(LinuxBoxGuestPingPayload(sequence: expected))
    )
    guard result.sequence == expected else {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "the guest heartbeat sequence did not match"
      )
    }
    try requirePinnedBootID(result.bootID.value)
  }

  private func requirePinnedBootID(_ candidate: UUID) throws {
    guard candidate == bootID else {
      throw LinuxVirtualMachineAgentClientError.identityMismatch
    }
  }

  private func expire(_ requestID: UUID) async {
    guard pending[requestID] != nil else { return }
    await connectionFailed(LinuxVirtualMachineAgentClientError.timedOut)
  }

  private func connectionFailed(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    readerTask?.cancel()
    heartbeatTask?.cancel()
    transport.close()
    failPending(with: error)
    if let failureHandler {
      await failureHandler(error)
    }
  }

  private func failPending(with error: any Error) {
    let responses = pending.values
    pending.removeAll()
    for response in responses {
      response.timeoutTask.cancel()
      response.continuation.resume(throwing: error)
    }
  }

  private static func responseRequestID(_ data: Data) throws -> UUID {
    let root = try StrictJSONDocument.parse(data)
    let object = try root.object(
      requiredKeys: ["schemaVersion", "requestID", "ok"],
      optionalKeys: ["data", "error"]
    )
    guard object["schemaVersion"]?.integer(as: Int.self)
      == LinuxBoxGuestProtocol.schemaVersion,
      let requestID = object["requestID"]?.string,
      object["ok"]?.bool != nil
    else {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "the guest response envelope is invalid"
      )
    }
    return try CanonicalUUID(string: requestID).value
  }

  private static func validateResponseData(
    _ data: Data,
    expectedRequestID: UUID,
    operation: LinuxBoxGuestOperation
  ) throws {
    let root = try StrictJSONDocument.parse(data)
    let object = try root.object(
      requiredKeys: ["schemaVersion", "requestID", "ok"],
      optionalKeys: ["data", "error"]
    )
    guard object["schemaVersion"]?.integer(as: Int.self)
      == LinuxBoxGuestProtocol.schemaVersion,
      let requestID = object["requestID"]?.string,
      try CanonicalUUID(string: requestID).value == expectedRequestID,
      let ok = object["ok"]?.bool
    else {
      throw LinuxVirtualMachineAgentClientError.protocolViolation(
        "the guest response envelope is invalid"
      )
    }
    if ok {
      _ = try root.object(
        exactKeys: ["schemaVersion", "requestID", "ok", "data"]
      )
      guard let value = object["data"] else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the guest response omitted data"
        )
      }
      try validateResult(value, operation: operation)
    } else {
      _ = try root.object(
        exactKeys: ["schemaVersion", "requestID", "ok", "error"]
      )
      guard let value = object["error"] else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the guest response omitted an error"
        )
      }
      let error = try value.object(
        requiredKeys: ["code", "message"],
        optionalKeys: ["details"]
      )
      guard let rawCode = error["code"]?.string,
        let code = LinuxBoxGuestErrorCode(rawValue: rawCode),
        let message = error["message"]?.string,
        message.utf8.count <= 512
      else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the guest error is invalid"
        )
      }
      if let details = error["details"] {
        guard operation == .exec,
          code == .execFailed || code == .outputLimit
            || code == .operationTimedOut
        else {
          throw LinuxVirtualMachineAgentClientError.protocolViolation(
            "guest exec details are invalid"
          )
        }
        try validateResult(details, operation: .exec)
      }
    }
  }

  private static func validateResult(
    _ value: StrictJSONValue,
    operation: LinuxBoxGuestOperation
  ) throws {
    switch operation {
    case .hello:
      _ = try value.object(
        exactKeys: [
          "challenge", "protocol", "imageID", "imageBuildRevision", "bootID", "state",
        ]
      )
    case .configure:
      let result = try value.object(
        exactKeys: ["profile", "state", "uplink", "authorizationPublished"]
      )
      guard let profile = result["profile"]?.string,
        LinuxBoxProfile(rawValue: profile) != nil,
        let state = result["state"]?.string,
        LinuxBoxGuestState(rawValue: state) != nil,
        result["uplink"]?.string != nil,
        result["authorizationPublished"]?.bool != nil
      else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the configure result is invalid"
        )
      }
    case .ping:
      let result = try value.object(exactKeys: ["sequence", "bootID", "state"])
      guard result["sequence"]?.integer(as: UInt64.self) != nil,
        let bootID = result["bootID"]?.string,
        (try? CanonicalUUID(string: bootID)) != nil,
        let state = result["state"]?.string,
        LinuxBoxGuestState(rawValue: state) != nil
      else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the ping result is invalid"
        )
      }
    case .status:
      let result = try value.object(
        exactKeys: [
          "profile", "state", "bootID", "uplink", "authorizationActive",
          "networkdActive", "singBoxActive", "baselineActive", "ready",
          "activeOperation",
        ]
      )
      let validProfile = result["profile"] == .null
        || (result["profile"]?.string).flatMap(LinuxBoxProfile.init(rawValue:)) != nil
      let validUplink = result["uplink"] == .null || result["uplink"]?.string != nil
      let validOperation = result["activeOperation"] == .null
        || (result["activeOperation"]?.string).flatMap(LinuxBoxGuestOperation.init(rawValue:)) != nil
      guard validProfile,
        let state = result["state"]?.string,
        LinuxBoxGuestState(rawValue: state) != nil,
        let bootID = result["bootID"]?.string,
        (try? CanonicalUUID(string: bootID)) != nil,
        validUplink,
        validOperation,
        result["authorizationActive"]?.bool != nil,
        result["networkdActive"]?.bool != nil,
        result["singBoxActive"]?.bool != nil,
        result["baselineActive"]?.bool != nil,
        result["ready"]?.bool != nil
      else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the status result is invalid"
        )
      }
    case .exec:
      _ = try value.object(
        exactKeys: ["exitCode", "stdoutBase64", "stderrBase64"]
      )
    case .verify:
      let result = try value.object(exactKeys: ["egress", "doh", "checks"])
      let egress = result["egress"]
      let doh = result["doh"]
      switch (egress, doh) {
      case (.some(.null), .some(.null)):
        break
      case (.some(.object), .some(.object)):
        guard let egress, let doh else {
          throw LinuxVirtualMachineAgentClientError.protocolViolation(
            "the verification result is invalid"
          )
        }
        let egressObject = try egress.object(
          exactKeys: ["curlIP", "chromiumIP", "isp", "country"]
        )
        let dohObject = try doh.object(exactKeys: ["address", "serverName"])
        guard egressObject["curlIP"]?.string != nil,
          egressObject["chromiumIP"]?.string != nil,
          egressObject["isp"]?.string != nil,
          egressObject["country"]?.string != nil,
          dohObject["address"]?.string != nil,
          dohObject["serverName"]?.string != nil
        else {
          throw LinuxVirtualMachineAgentClientError.protocolViolation(
            "the verification proxy fields are invalid"
          )
        }
      default:
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the verification result has inconsistent proxy fields"
        )
      }
      guard let checks = result["checks"]?.array else {
        throw LinuxVirtualMachineAgentClientError.protocolViolation(
          "the verification checks are invalid"
        )
      }
      for check in checks {
        let object = try check.object(
          requiredKeys: ["name", "ok"],
          optionalKeys: ["details"]
        )
        guard object["name"]?.string != nil,
          object["ok"]?.bool != nil,
          object["details"] == nil || object["details"] == .null
            || object["details"]?.string != nil
        else {
          throw LinuxVirtualMachineAgentClientError.protocolViolation(
            "the verification check is invalid"
          )
        }
      }
    case .quiesce:
      _ = try value.object(
        exactKeys: [
          "state", "singBoxStopped", "networkClientsStopped", "runtimeSecretsRemoved",
          "baselineActive",
        ]
      )
    case .shutdown:
      _ = try value.object(exactKeys: ["accepted"])
    }
  }
}

enum LinuxVirtualMachineAgentClientError: LocalizedError, Equatable, Sendable {
  case connectionClosed
  case timedOut
  case identityMismatch
  case protocolViolation(String)
  case guest(
    code: LinuxBoxGuestErrorCode,
    message: String,
    details: LinuxBoxGuestExecResult? = nil
  )
  case securityInvariant(String)

  var errorDescription: String? {
    switch self {
    case .connectionClosed:
      "The Linux box guest-agent connection closed."
    case .timedOut:
      "The Linux box guest-agent operation timed out."
    case .identityMismatch:
      "The Linux box guest agent does not match the trusted image descriptor."
    case .protocolViolation(let reason):
      "The Linux box guest-agent protocol failed: \(reason)"
    case .guest(let code, let message, _):
      "The Linux box guest agent rejected the operation (\(code.rawValue)): \(message)"
    case .securityInvariant(let reason):
      "The Linux box guest security invariant failed: \(reason)"
    }
  }
}
