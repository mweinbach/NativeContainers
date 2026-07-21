import Darwin
import XCTest

final class NativeContainersCLIContractTests: XCTestCase, @unchecked Sendable {
  func testParserCoversCommandsDefaultsAndOverrides() throws {
    let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let idString = id.uuidString.lowercased()
    let cases: [([String], NativeContainersControlOperation, Int)] = [
      (["linux-box", "doctor"], .doctor, 30),
      (["image", "prepare"], .imagePrepare, 1_800),
      (["linux-box", "list"], .list, 30),
      (["linux-box", "create", "--name", "box"], .create, 1_800),
      (["linux-box", "status", "--id", idString], .status, 30),
      (["linux-box", "start", "--id", idString], .start, 300),
      (["linux-box", "pause", "--id", idString], .pause, 120),
      (["linux-box", "resume", "--id", idString], .resume, 120),
      (["linux-box", "exec", "--id", idString, "--", "/usr/bin/id"], .exec, 300),
      (["linux-box", "verify", "--id", idString], .verify, 300),
      (["linux-box", "refresh", "--id", idString], .refresh, 300),
      (["linux-box", "stop", "--id", idString], .stop, 120),
      (["linux-box", "destroy", "--id", idString], .destroy, 120),
      (["linux-box", "smoke", "--name", "box"], .smoke, 3_600),
    ]

    for (arguments, operation, timeout) in cases {
      let command = try NativeContainersCLIParser.parse(arguments, requestID: id)
      XCTAssertEqual(command.request.operation, operation)
      XCTAssertEqual(command.request.timeoutSeconds, timeout)
      XCTAssertEqual(command.defaultTimeoutSeconds, timeout)
    }

    let overridden = try NativeContainersCLIParser.parse(
      ["--timeout", "45", "linux-box", "list"],
      requestID: id
    )
    XCTAssertEqual(overridden.request.timeoutSeconds, 45)
    XCTAssertEqual(overridden.defaultTimeoutSeconds, 30)
  }

  func testParserDefaultsCreateResourcesAndPreservesExecArgv() throws {
    let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let created = try NativeContainersCLIParser.parse(
      ["linux-box", "create", "--name", "box"],
      requestID: id
    )
    guard case .create(let payload) = created.request.payload else {
      return XCTFail("create payload missing")
    }
    XCTAssertEqual(payload.name, "box")
    XCTAssertEqual(payload.cpuCount, 4)
    XCTAssertEqual(payload.memoryBytes, 8 * 1_073_741_824)
    XCTAssertEqual(payload.diskBytes, 32 * 1_073_741_824)
    XCTAssertEqual(payload.profile, .standard)


    let exec = try NativeContainersCLIParser.parse(
      [
        "linux-box", "exec", "--id", id.uuidString.lowercased(), "--",
        "/usr/bin/printf", "%s", "hello world",
      ],
      requestID: id
    )
    guard case .exec(let execPayload) = exec.request.payload else {
      return XCTFail("exec payload missing")
    }
    XCTAssertEqual(execPayload.id.value, id)
    XCTAssertEqual(execPayload.argv, ["/usr/bin/printf", "%s", "hello world"])
  }

  func testParserRejectsNoncanonicalAndOutOfRangeInput() {
    let uppercaseID = "00112233-4455-6677-8899-AABBCCDDEEFF"
    XCTAssertThrowsError(
      try NativeContainersCLIParser.parse(
        ["linux-box", "status", "--id", uppercaseID]
      )
    )
    XCTAssertThrowsError(
      try NativeContainersCLIParser.parse(
        ["--timeout", "4", "linux-box", "list"]
      )
    )
    XCTAssertThrowsError(
      try NativeContainersCLIParser.parse(
        ["linux-box", "list", "--timeout", "30"]
      )
    )
    XCTAssertThrowsError(
      try NativeContainersCLIParser.parse(
        ["linux-box", "exec", "--id", UUID().uuidString.lowercased()]
      )
    )
  }

  func testClientEmitsOneCanonicalSuccessDocument() async throws {
    let fixture = try ControlServerFixture()
    defer { fixture.close() }
    let command = try NativeContainersCLIParser.parse(
      ["linux-box", "list"],
      requestID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    )
    let response = try JSONEncoder().encode(
      NativeContainersControlResponse(
        requestID: command.request.requestID.value,
        data: LinuxBoxListResult(boxes: [])
      )
    )
    let server = fixture.respond(with: response)

    let result = try await NativeContainersCLIClient(
      socketURL: fixture.socketURL,
      executableURL: URL(fileURLWithPath: "/tmp/nativecontainersctl")
    ).execute(command)
    _ = try await server.value

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertEqual(result.stdout.last, 0x0a)
    let document = result.stdout.dropLast()
    XCTAssertNoThrow(try StrictJSONDocument.parse(Data(document)))
    XCTAssertEqual(document.filter { $0 == 0x0a }.count, 0)
  }

  func testClientReturnsTypedExecFailureWithDetails() async throws {
    let fixture = try ControlServerFixture()
    defer { fixture.close() }
    let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let command = try NativeContainersCLIParser.parse(
      ["linux-box", "exec", "--id", id.uuidString.lowercased(), "--", "/usr/bin/false"],
      requestID: UUID()
    )
    let details = LinuxBoxExecResult(
      id: CanonicalUUID(id),
      exitCode: 1,
      stdoutBase64: CanonicalBase64(Data()),
      stderrBase64: CanonicalBase64(Data("failed\n".utf8))
    )
    let response = try JSONEncoder().encode(
      NativeContainersControlResponse<String>(
        requestID: command.request.requestID.value,
        error: NativeContainersControlFailure(
          code: .guestExit,
          message: "The guest command exited with code 1.",
          details: details
        )
      )
    )
    let server = fixture.respond(with: response)

    let result = try await NativeContainersCLIClient(
      socketURL: fixture.socketURL,
      executableURL: URL(fileURLWithPath: "/tmp/nativecontainersctl")
    ).execute(command)
    _ = try await server.value

    XCTAssertEqual(result.exitCode, 2)
    XCTAssertTrue(result.stderr.isEmpty)
    let root = try StrictJSONDocument.parse(Data(result.stdout.dropLast()))
    let error = try root.object(exactKeys: ["schemaVersion", "requestID", "ok", "error"])["error"]?
      .object(requiredKeys: ["code", "message"], optionalKeys: ["details"])
    XCTAssertEqual(error?["code"]?.string, "guest_exit")
    XCTAssertNotNil(error?["details"])
  }

  func testClientRejectsMismatchedResponseAndExtraInput() async throws {
    let command = try NativeContainersCLIParser.parse(
      ["linux-box", "list"],
      requestID: UUID()
    )

    do {
      let fixture = try ControlServerFixture()
      defer { fixture.close() }
      let response = try JSONEncoder().encode(
        NativeContainersControlResponse(
          requestID: UUID(),
          data: LinuxBoxListResult(boxes: [])
        )
      )
      let server = fixture.respond(with: response)
      do {
        _ = try await NativeContainersCLIClient(
          socketURL: fixture.socketURL,
          executableURL: URL(fileURLWithPath: "/tmp/nativecontainersctl")
        ).execute(command)
        XCTFail("request-ID mismatch must fail")
      } catch let error as NativeContainersCLIError {
        guard case .protocolError = error else {
          return XCTFail("unexpected error: \(error)")
        }
      }
      _ = try await server.value
    }

    do {
      let fixture = try ControlServerFixture()
      defer { fixture.close() }
      let response = try JSONEncoder().encode(
        NativeContainersControlResponse(
          requestID: command.request.requestID.value,
          data: LinuxBoxListResult(boxes: [])
        )
      )
      let server = fixture.respond(
        with: response,
        trailingByte: 0x7b,
        trailingDelayMilliseconds: 50
      )
      do {
        _ = try await NativeContainersCLIClient(
          socketURL: fixture.socketURL,
          executableURL: URL(fileURLWithPath: "/tmp/nativecontainersctl")
        ).execute(command)
        XCTFail("extra response input must fail")
      } catch let error as NativeContainersCLIError {
        guard case .protocolError = error else {
          return XCTFail("unexpected error: \(error)")
        }
      }
      _ = try await server.value
    }
  }

  func testClientReportsUnavailableWithoutEnclosingApp() async throws {
    let socketURL = URL(fileURLWithPath: "/tmp/nc-missing-\(UUID().uuidString.prefix(8)).sock")
    let command = try NativeContainersCLIParser.parse(["linux-box", "list"])
    do {
      _ = try await NativeContainersCLIClient(
        socketURL: socketURL,
        executableURL: URL(fileURLWithPath: "/tmp/nativecontainersctl")
      ).execute(command)
      XCTFail("missing app and socket must fail")
    } catch let error as NativeContainersCLIError {
      XCTAssertEqual(error, .appUnavailable)
    }
  }
}

private final class ControlServerFixture: @unchecked Sendable {
  let socketURL: URL
  private let listener: Int32

  init() throws {
    socketURL = URL(fileURLWithPath: "/tmp/nc-cli-\(UUID().uuidString.prefix(8)).sock")
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw posixError() }
    do {
      guard Darwin.fcntl(listener, F_SETFD, FD_CLOEXEC) == 0 else {
        throw posixError()
      }
      var address = try socketAddress(socketURL)
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, Darwin.listen(listener, 1) == 0 else {
        throw posixError()
      }
    } catch {
      Darwin.close(listener)
      try? FileManager.default.removeItem(at: socketURL)
      throw error
    }
  }

  func respond(
    with response: Data,
    trailingByte: UInt8? = nil,
    trailingDelayMilliseconds: Int = 0
  ) -> Task<NativeContainersControlRequest, Error> {
    let listener = self.listener
    return Task.detached {
      let client = Darwin.accept(listener, nil, nil)
      guard client >= 0 else { throw posixError() }
      defer { Darwin.close(client) }
      let requestData = try BoundedJSONFrameCodec.readPayload(from: client)
      let request = try NativeContainersControlRequest.decodeStrict(requestData)
      try BoundedJSONFrameCodec.write(
        try BoundedJSONFrameCodec.encodePayload(response),
        to: client
      )
      if var trailingByte {
        if trailingDelayMilliseconds > 0 {
          try await Task.sleep(
            for: .milliseconds(trailingDelayMilliseconds)
          )
        }
        guard Darwin.write(client, &trailingByte, 1) == 1 else {
          throw posixError()
        }
      }
      return request
    }
  }

  func close() {
    Darwin.shutdown(listener, SHUT_RDWR)
    Darwin.close(listener)
    try? FileManager.default.removeItem(at: socketURL)
  }
}

private func socketAddress(_ url: URL) throws -> sockaddr_un {
  let bytes = Array(url.path.utf8)
  guard bytes.count + 1 <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
    throw POSIXError(.ENAMETOOLONG)
  }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    for (index, byte) in bytes.enumerated() { destination[index] = byte }
  }
  return address
}

private func posixError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
