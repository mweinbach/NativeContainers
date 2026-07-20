import AppKit
import Darwin
import Foundation

struct NativeContainersCLICommand: Equatable, Sendable {
  let request: NativeContainersControlRequest
  let defaultTimeoutSeconds: Int
}

enum NativeContainersCLIError: Error, Equatable, LocalizedError, Sendable {
  case invalidArguments(String)
  case appUnavailable
  case protocolError(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message): message
    case .appUnavailable: "The NativeContainers app could not be reached."
    case .protocolError(let message): message
    }
  }
}

enum NativeContainersCLIParser {
  static func parse(_ arguments: [String], requestID: UUID = UUID()) throws -> NativeContainersCLICommand {
    var values = arguments[...]
    var timeout: Int?
    if values.first == "--timeout" {
      values.removeFirst()
      guard let value = values.first else { throw NativeContainersCLIError.invalidArguments("--timeout requires seconds") }
      values.removeFirst()
      timeout = try parseTimeout(value)
    } else if values.contains("--timeout") {
      throw NativeContainersCLIError.invalidArguments("--timeout must precede the command")
    }
    guard let root = values.first else { throw NativeContainersCLIError.invalidArguments("a command is required") }
    values.removeFirst()
    let operation: NativeContainersControlOperation
    var payload: NativeContainersControlPayload = .empty
    var defaultTimeoutSeconds: Int

    if root == "image" {
      guard values.first == "prepare" else { throw NativeContainersCLIError.invalidArguments("expected image prepare") }
      values.removeFirst()
      guard values.isEmpty else { throw NativeContainersCLIError.invalidArguments("image prepare takes no options") }
      operation = .imagePrepare
      defaultTimeoutSeconds = 1_800
    } else {
      guard root == "linux-box", let subcommand = values.first else {
        throw NativeContainersCLIError.invalidArguments("expected linux-box or image")
      }
      values.removeFirst()
      operation = try parseOperation(subcommand)
      defaultTimeoutSeconds = Self.defaultTimeout(for: operation)
      payload = try parsePayload(operation, values: &values)
    }

    let effectiveTimeout = timeout ?? defaultTimeoutSeconds
    let request = try NativeContainersControlRequest(
      requestID: requestID,
      operation: operation,
      timeoutSeconds: effectiveTimeout,
      payload: payload
    )
    return NativeContainersCLICommand(request: request, defaultTimeoutSeconds: defaultTimeoutSeconds)
  }

  private static func parseOperation(_ value: String) throws -> NativeContainersControlOperation {
    guard let operation = NativeContainersControlOperation.allCases.first(where: { raw in
      raw.rawValue == "linux-box.\(value)"
    }) else {
      throw NativeContainersCLIError.invalidArguments("unknown linux-box command")
    }
    return operation
  }

  private static func defaultTimeout(for operation: NativeContainersControlOperation) -> Int {
    switch operation {
    case .doctor, .list, .status: 30
    case .pause, .resume, .stop, .destroy: 120
    case .start, .verify, .refresh, .exec: 300
    case .smoke: 3_600
    case .create, .imagePrepare: 1_800
    }
  }

  private static func parsePayload(
    _ operation: NativeContainersControlOperation,
    values: inout ArraySlice<String>
  ) throws -> NativeContainersControlPayload {
    switch operation {
    case .doctor, .list:
      guard values.isEmpty else { throw NativeContainersCLIError.invalidArguments("the command takes no options") }
      return .empty
    case .create:
      guard values.first == "--name" else { throw NativeContainersCLIError.invalidArguments("create requires --name") }
      values.removeFirst()
      guard let name = values.first else { throw NativeContainersCLIError.invalidArguments("--name requires a value") }
      values.removeFirst()
      var cpuCount = 4
      var memoryBytes: UInt64 = 8 * 1_073_741_824
      var diskBytes: UInt64 = 32 * 1_073_741_824
      var seen = Set<String>()
      var profile: LinuxBoxProfile = .standard
      while !values.isEmpty {
        let option = values.removeFirst()
        guard ["--cpus", "--memory-gib", "--disk-gib", "--profile"].contains(option),
          seen.insert(option).inserted else {
          throw NativeContainersCLIError.invalidArguments("unknown or duplicate create option")
        }
        guard let argument = values.first else { throw NativeContainersCLIError.invalidArguments("\(option) requires a value") }
        values.removeFirst()
        switch option {
        case "--cpus": cpuCount = try parseInt(argument, option: option)
        case "--memory-gib": memoryBytes = try parseGiB(argument, option: option)
        case "--disk-gib": diskBytes = try parseGiB(argument, option: option)
        default:
          guard let parsed = LinuxBoxProfile(rawValue: argument) else {
            throw NativeContainersCLIError.invalidArguments("--profile must be standard or residential")
          }
          profile = parsed
        }
      }
      return .create(LinuxBoxCreatePayload(name: name, cpuCount: cpuCount, memoryBytes: memoryBytes, diskBytes: diskBytes, profile: profile))
    case .exec:
      let id = try parseID(&values)
      guard values.first == "--" else { throw NativeContainersCLIError.invalidArguments("exec requires -- before argv") }
      values.removeFirst()
      guard !values.isEmpty else { throw NativeContainersCLIError.invalidArguments("exec requires argv") }
      return .exec(LinuxBoxExecPayload(id: id, argv: Array(values)))
    case .smoke:
      guard values.count >= 2, values.first == "--name" else { throw NativeContainersCLIError.invalidArguments("smoke requires --name") }
      values.removeFirst()
      guard let name = values.popFirst() else { throw NativeContainersCLIError.invalidArguments("--name requires a value") }
      var profile: LinuxBoxProfile = .standard
      if !values.isEmpty {
        guard values.count == 2, values.first == "--profile" else { throw NativeContainersCLIError.invalidArguments("unknown smoke option") }
        values.removeFirst()
        guard let raw = values.popFirst(), let parsed = LinuxBoxProfile(rawValue: raw) else {
          throw NativeContainersCLIError.invalidArguments("--profile must be standard or residential")
        }
        profile = parsed
      }
      return .smoke(LinuxBoxSmokePayload(name: name, profile: profile))
    case .status, .start, .pause, .resume, .verify, .refresh, .stop, .destroy:
      let id = try parseID(&values)
      guard values.isEmpty else { throw NativeContainersCLIError.invalidArguments("the command takes no extra options") }
      return .id(LinuxBoxIDPayload(id: id))
    case .imagePrepare:
      throw NativeContainersCLIError.invalidArguments("invalid image command")
    }
  }

  private static func parseID(_ values: inout ArraySlice<String>) throws -> CanonicalUUID {
    guard values.count >= 2, values.first == "--id" else {
      throw NativeContainersCLIError.invalidArguments("the command requires --id UUID")
    }
    values.removeFirst()
    guard let value = values.popFirst() else { throw NativeContainersCLIError.invalidArguments("--id requires a value") }
    do { return try CanonicalUUID(string: value) } catch { throw NativeContainersCLIError.invalidArguments("--id must be a lowercase UUID") }
  }

  private static func parseTimeout(_ value: String) throws -> Int {
    guard let parsed = Int(value), (5...3_600).contains(parsed) else {
      throw NativeContainersCLIError.invalidArguments("--timeout must be in 5...3600")
    }
    return parsed
  }

  private static func parseInt(_ value: String, option: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else { throw NativeContainersCLIError.invalidArguments("\(option) must be a positive integer") }
    return parsed
  }

  private static func parseGiB(_ value: String, option: String) throws -> UInt64 {
    guard let parsed = UInt64(value), parsed > 0, parsed <= UInt64.max / 1_073_741_824 else {
      throw NativeContainersCLIError.invalidArguments("\(option) must be a positive GiB value")
    }
    return parsed * 1_073_741_824
  }
}

struct NativeContainersCLIExecution: Equatable, Sendable {
  let stdout: Data
  let stderr: Data
  let exitCode: Int32
}

final class NativeContainersCLIClient: @unchecked Sendable {
  private static let defaultSocketURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "NativeContainers", directoryHint: .isDirectory)
    .appending(path: "Control", directoryHint: .isDirectory)
    .appending(path: "control-v1.sock")

  private let socketURL: URL
  private let appURL: URL?
  private let clock = ContinuousClock()

  init(socketURL: URL? = nil, executableURL: URL? = nil) {
    self.socketURL = (socketURL ?? Self.defaultSocketURL).standardizedFileURL
    appURL = Self.findEnclosingApp(
      executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    )
  }

  func execute(
    _ command: NativeContainersCLICommand
  ) async throws -> NativeContainersCLIExecution {
    let descriptor = try await connectOrLaunch()
    defer { Darwin.close(descriptor) }
    guard peerIsCurrentUser(descriptor) else {
      throw NativeContainersCLIError.appUnavailable
    }
    do {
      try setSocketTimeouts(
        descriptor,
        seconds: command.request.timeoutSeconds + 1
      )
      let requestFrame = try BoundedJSONFrameCodec.encode(command.request)
      try BoundedJSONFrameCodec.write(requestFrame, to: descriptor)
      let response = try BoundedJSONFrameCodec.readPayload(from: descriptor)
      guard responseEnded(descriptor) else {
        throw NativeContainersCLIError.protocolError(
          "the server did not close after exactly one response"
        )
      }
      let validated = try Self.validateAndCanonicalizeResponse(
        response,
        expectedRequestID: command.request.requestID
      )
      return NativeContainersCLIExecution(
        stdout: validated.data + Data([0x0a]),
        stderr: Data(),
        exitCode: validated.ok ? 0 : 2
      )
    } catch let error as NativeContainersCLIError {
      throw error
    } catch {
      throw NativeContainersCLIError.protocolError(
        "the server response could not be completed"
      )
    }
  }

  private func connectOrLaunch() async throws -> Int32 {
    do { return try connect() } catch {
      guard let appURL else { throw NativeContainersCLIError.appUnavailable }
      try await launch(appURL)
      let deadline = clock.now.advanced(by: .seconds(10))
      while clock.now < deadline {
        do { return try connect() } catch {
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      throw NativeContainersCLIError.appUnavailable
    }
  }

  private func connect() throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NativeContainersCLIError.appUnavailable }
    guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
      Darwin.close(descriptor)
      throw NativeContainersCLIError.appUnavailable
    }
    do {
      let bytes = Array(socketURL.path.utf8)
      guard bytes.count + 1 <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
        throw NativeContainersCLIError.appUnavailable
      }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in bytes.enumerated() { destination[index] = byte }
      }
      let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard result == 0 else { throw NativeContainersCLIError.appUnavailable }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func launch(_ appURL: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private static func validateAndCanonicalizeResponse(
    _ data: Data,
    expectedRequestID: CanonicalUUID
  ) throws -> (data: Data, ok: Bool) {
    do {
      let root = try StrictJSONDocument.parse(data)
      guard case .object(let members) = root,
        let ok = members["ok"]?.bool
      else {
        throw StrictJSONError.invalidValue("the control response must be an object")
      }
      let expectedKeys: Set<String> = ok
        ? ["schemaVersion", "requestID", "ok", "data"]
        : ["schemaVersion", "requestID", "ok", "error"]
      let object = try root.object(exactKeys: expectedKeys)
      guard object["schemaVersion"]?.integer(as: Int.self)
        == NativeContainersControlProtocol.schemaVersion,
        let requestIDValue = object["requestID"]?.string,
        try CanonicalUUID(string: requestIDValue) == expectedRequestID
      else {
        throw StrictJSONError.invalidValue("the response identity is invalid")
      }
      if ok {
        guard case .object = object["data"] else {
          throw StrictJSONError.invalidValue("a successful response requires object data")
        }
      } else {
        let error = try object["error"]?.object(
          requiredKeys: ["code", "message"],
          optionalKeys: ["details"]
        )
        guard let error,
          let rawCode = error["code"]?.string,
          let code = NativeContainersControlErrorCode(rawValue: rawCode),
          error["message"]?.string != nil
        else {
          throw StrictJSONError.invalidValue("a failure response requires a typed error")
        }
        if let details = error["details"] {
          guard code == .guestExit || code == .outputLimit
            || code == .operationTimedOut
          else {
            throw StrictJSONError.invalidValue("exec details require an exec failure code")
          }
          try validateExecDetails(details)
        }
      }
      let value = try JSONSerialization.jsonObject(with: data)
      let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      return (canonical, ok)
    } catch {
      throw NativeContainersCLIError.protocolError("the server response is invalid")
    }
  }

  private static func validateExecDetails(_ value: StrictJSONValue) throws {
    let details = try value.object(
      exactKeys: ["id", "exitCode", "stdoutBase64", "stderrBase64"]
    )
    guard let id = details["id"]?.string,
      let exitCode = details["exitCode"]?.integer(as: Int32.self),
      let stdout = details["stdoutBase64"]?.string,
      let stderr = details["stderrBase64"]?.string
    else {
      throw StrictJSONError.invalidValue("exec failure details are invalid")
    }
    _ = exitCode
    _ = try CanonicalUUID(string: id)
    let stdoutData = try CanonicalBase64(string: stdout).data
    let stderrData = try CanonicalBase64(string: stderr).data
    guard stdoutData.count <= 256 * 1_024,
      stderrData.count <= 256 * 1_024
    else {
      throw StrictJSONError.invalidValue("exec failure details exceed the output bound")
    }
  }

  private static func findEnclosingApp(_ executableURL: URL) -> URL? {
    var url = executableURL.standardizedFileURL
    while url.path != "/" {
      if url.pathExtension == "app" { return url }
      url.deleteLastPathComponent()
    }
    return nil
  }

  private func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
  }

  private func setSocketTimeouts(
    _ descriptor: Int32,
    seconds: Int
  ) throws {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    let receive = withUnsafePointer(to: &timeout) {
      Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, size)
    }
    guard receive == 0 else {
      throw NativeContainersCLIError.protocolError(
        "the response deadline could not be configured"
      )
    }
    let send = withUnsafePointer(to: &timeout) {
      Darwin.setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, size)
    }
    guard send == 0 else {
      throw NativeContainersCLIError.protocolError(
        "the request deadline could not be configured"
      )
    }
  }

  private func responseEnded(_ descriptor: Int32) -> Bool {
    while true {
      var state = pollfd(
        fd: descriptor,
        events: Int16(POLLIN | POLLHUP),
        revents: 0
      )
      let polled = Darwin.poll(&state, 1, 1_000)
      if polled == 0 { return false }
      if polled < 0 {
        if errno == EINTR { continue }
        return false
      }
      var byte: UInt8 = 0
      let received = Darwin.recv(
        descriptor,
        &byte,
        1,
        MSG_PEEK | MSG_DONTWAIT
      )
      if received == 0 { return true }
      if received > 0 { return false }
      if errno == EINTR { continue }
      return false
    }
  }
}
