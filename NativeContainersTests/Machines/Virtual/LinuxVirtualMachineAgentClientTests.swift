import Darwin
import Foundation
import Testing
@testable import NativeContainers

struct LinuxVirtualMachineAgentClientTests {
  @Test
  func establishesIdentityAndProvesFailClosedStatusOverFragmentedFrames() async throws {
    let pair = try SocketPair()
    let descriptor = try trustedDescriptor()
    let guest = Task.detached {
      defer { Darwin.close(pair.guest) }
      for operation in ["hello", "status"] {
        let requestData = try BoundedJSONFrameCodec.readPayload(from: pair.guest)
        let request = try StrictJSONDocument.parse(requestData).object(
          exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
        )
        #expect(request["operation"]?.string == operation)
        let requestID = try #require(request["requestID"]?.string)
        let responseData: Data
        if operation == "hello" {
          let payload = try request["payload"]!.object(exactKeys: ["challenge"])
          responseData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "requestID": requestID,
            "ok": true,
            "data": [
              "challenge": try #require(payload["challenge"]?.string),
              "protocol": 2,
              "imageID": descriptor.imageID,
              "imageBuildRevision": descriptor.imageBuildRevision,
              "bootID": "01234567-89ab-cdef-8123-456789abcdef",
              "state": "awaitingConfiguration",
            ],
          ])
        } else {
          responseData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "requestID": requestID,
            "ok": true,
            "data": [
              "profile": "standard",
              "state": "awaitingConfiguration",
              "bootID": "01234567-89ab-cdef-8123-456789abcdef",
              "uplink": NSNull(),
              "authorizationActive": false,
              "networkdActive": false,
              "singBoxActive": false,
              "baselineActive": true,
              "ready": false,
              "activeOperation": NSNull(),
            ],
          ])
        }
        let frame = try BoundedJSONFrameCodec.encodePayload(responseData)
        for byte in frame {
          var value = byte
          let written = withUnsafePointer(to: &value) {
            Darwin.write(pair.guest, $0, 1)
          }
          #expect(written == 1)
        }
      }
    }

    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host,
      label: "test.nativecontainers.agent"
    ) {
      Darwin.close(pair.host)
    }
    let client = LinuxVirtualMachineAgentClient(transport: transport)
    let status = try await client.establish(descriptor: descriptor, timeoutSeconds: 5)
    #expect(status.state == .awaitingConfiguration)
    #expect(status.baselineActive)
    #expect(!status.authorizationActive)
    #expect(!status.networkdActive)
    #expect(!status.singBoxActive)
    #expect(!status.ready)
    await client.close()
    try await guest.value
  }

  @Test
  func rejectsMismatchedImageIdentity() async throws {
    let pair = try SocketPair()
    let descriptor = try trustedDescriptor()
    let guest = Task.detached {
      defer { Darwin.close(pair.guest) }
      let requestData = try BoundedJSONFrameCodec.readPayload(from: pair.guest)
      let request = try StrictJSONDocument.parse(requestData).object(
        exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
      )
      let payload = try request["payload"]!.object(exactKeys: ["challenge"])
      let response = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "requestID": try #require(request["requestID"]?.string),
        "ok": true,
        "data": [
          "challenge": try #require(payload["challenge"]?.string),
          "protocol": 2,
          "imageID": "wrong-image",
          "imageBuildRevision": descriptor.imageBuildRevision,
          "bootID": "01234567-89ab-cdef-8123-456789abcdef",
          "state": "awaitingConfiguration",
        ],
      ])
      try BoundedJSONFrameCodec.write(
        BoundedJSONFrameCodec.encodePayload(response),
        to: pair.guest
      )
    }
    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host,
      label: "test.nativecontainers.agent.identity"
    ) {
      Darwin.close(pair.host)
    }
    let client = LinuxVirtualMachineAgentClient(transport: transport)
    await #expect(throws: LinuxVirtualMachineAgentClientError.identityMismatch) {
      _ = try await client.establish(descriptor: descriptor, timeoutSeconds: 5)
    }
    await client.close()
    try await guest.value
  }

  @Test
  func preservesBoundedGuestExecFailureDetails() async throws {
    let pair = try SocketPair()
    let descriptor = try trustedDescriptor()
    let guest = Task.detached {
      defer { Darwin.close(pair.guest) }
      for operation in ["hello", "status", "exec"] {
        let requestData = try BoundedJSONFrameCodec.readPayload(from: pair.guest)
        let request = try StrictJSONDocument.parse(requestData).object(
          exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
        )
        #expect(request["operation"]?.string == operation)
        let requestID = try #require(request["requestID"]?.string)
        let response: [String: Any]
        switch operation {
        case "hello":
          let payload = try request["payload"]!.object(exactKeys: ["challenge"])
          response = [
            "schemaVersion": 2,
            "requestID": requestID,
            "ok": true,
            "data": [
              "challenge": try #require(payload["challenge"]?.string),
              "protocol": 2,
              "imageID": descriptor.imageID,
              "imageBuildRevision": descriptor.imageBuildRevision,
              "bootID": "01234567-89ab-cdef-8123-456789abcdef",
              "state": "awaitingConfiguration",
            ],
          ]
        case "status":
          response = [
            "schemaVersion": 2,
            "requestID": requestID,
            "ok": true,
            "data": [
              "profile": "standard",
              "state": "awaitingConfiguration",
              "bootID": "01234567-89ab-cdef-8123-456789abcdef",
              "uplink": NSNull(),
              "authorizationActive": false,
              "networkdActive": false,
              "singBoxActive": false,
              "baselineActive": true,
              "ready": false,
              "activeOperation": NSNull(),
            ]
          ]
        default:
          response = [
            "schemaVersion": 2,
            "requestID": requestID,
            "ok": false,
            "error": [
              "code": "output_limit",
              "message": "guest exec did not complete",
              "details": [
                "exitCode": -1,
                "stdoutBase64": Data("partial".utf8).base64EncodedString(),
                "stderrBase64": Data().base64EncodedString(),
              ],
            ],
          ]
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        try BoundedJSONFrameCodec.write(
          BoundedJSONFrameCodec.encodePayload(data),
          to: pair.guest
        )
      }
    }
    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host,
      label: "test.nativecontainers.agent.exec-details"
    ) {
      Darwin.close(pair.host)
    }
    let client = LinuxVirtualMachineAgentClient(transport: transport)
    _ = try await client.establish(descriptor: descriptor, timeoutSeconds: 5)
    do {
      _ = try await client.execute(argv: ["/usr/bin/false"], timeoutSeconds: 5)
      Issue.record("exec output limit must fail")
    } catch let error as LinuxVirtualMachineAgentClientError {
      guard case .guest(let code, _, let details) = error else {
        Issue.record("unexpected guest error: \(error)")
        await client.close()
        return
      }
      #expect(code == .outputLimit)
      #expect(details?.exitCode == -1)
      #expect(details?.stdoutBase64.data == Data("partial".utf8))
      #expect(details?.stderrBase64.data.isEmpty == true)
    }
    await client.close()
    try await guest.value
  }

  @Test
  func decodesStandardConfigureAndNullEvidenceVerifyResults() async throws {
    let pair = try SocketPair()
    let descriptor = try trustedDescriptor()
    let bootID = "01234567-89ab-cdef-8123-456789abcdef"
    let guest = Task.detached {
      defer { Darwin.close(pair.guest) }
      for operation in ["hello", "status", "configure", "verify"] {
        let requestData = try BoundedJSONFrameCodec.readPayload(from: pair.guest)
        let request = try StrictJSONDocument.parse(requestData).object(
          exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
        )
        #expect(request["operation"]?.string == operation)
        let requestID = try #require(request["requestID"]?.string)
        let data: [String: Any]
        switch operation {
        case "hello":
          let payload = try request["payload"]!.object(exactKeys: ["challenge"])
          data = [
            "challenge": try #require(payload["challenge"]?.string),
            "protocol": 2,
            "imageID": descriptor.imageID,
            "imageBuildRevision": descriptor.imageBuildRevision,
            "bootID": bootID,
            "state": "awaitingConfiguration",
          ]
        case "status":
          data = [
            "profile": "standard", "state": "awaitingConfiguration", "bootID": bootID,
            "uplink": NSNull(), "authorizationActive": false, "networkdActive": false,
            "singBoxActive": false, "baselineActive": true, "ready": false,
            "activeOperation": NSNull(),
          ]
        case "configure":
          let payload = try request["payload"]!.object(exactKeys: ["profile"])
          #expect(payload["profile"]?.string == "standard")
          data = [
            "profile": "standard", "state": "authorizing", "uplink": "standard",
            "authorizationPublished": true,
          ]
        default:
          let payload = try request["payload"]!.object(exactKeys: ["profile"])
          #expect(payload["profile"]?.string == "standard")
          data = [
            "egress": NSNull(), "doh": NSNull(),
            "checks": [["name": "baseline", "ok": true, "details": NSNull()]],
          ]
        }
        let response = try JSONSerialization.data(withJSONObject: [
          "schemaVersion": 2, "requestID": requestID, "ok": true, "data": data,
        ])
        try BoundedJSONFrameCodec.write(
          BoundedJSONFrameCodec.encodePayload(response), to: pair.guest
        )
      }
    }
    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host, label: "test.nativecontainers.agent.standard"
    ) { Darwin.close(pair.host) }
    let client = LinuxVirtualMachineAgentClient(transport: transport)
    _ = try await client.establish(descriptor: descriptor, timeoutSeconds: 5)
    let configured = try await client.configure(profile: .standard, timeoutSeconds: 5)
    #expect(configured.profile == .standard)
    #expect(configured.state == .authorizing)
    #expect(configured.authorizationPublished)
    let verified = try await client.verify(profile: .standard, timeoutSeconds: 5)
    #expect(verified.egress == nil)
    #expect(verified.doh == nil)
    #expect(verified.checks.count == 1)
    #expect(verified.checks[0].name == "baseline")
    #expect(verified.checks[0].ok)
    await client.close()
    try await guest.value
  }

  @Test
  func rejectsStandardVerifyWithResidentialEvidence() async throws {
    let pair = try SocketPair()
    let descriptor = try trustedDescriptor()
    let guest = Task.detached {
      defer { Darwin.close(pair.guest) }
      for operation in ["hello", "status", "verify"] {
        let requestData = try BoundedJSONFrameCodec.readPayload(from: pair.guest)
        let request = try StrictJSONDocument.parse(requestData).object(
          exactKeys: ["schemaVersion", "requestID", "operation", "timeoutSeconds", "payload"]
        )
        let requestID = try #require(request["requestID"]?.string)
        let data: [String: Any]
        if operation == "hello" {
          let payload = try request["payload"]!.object(exactKeys: ["challenge"])
          data = ["challenge": try #require(payload["challenge"]?.string), "protocol": 2,
            "imageID": descriptor.imageID, "imageBuildRevision": descriptor.imageBuildRevision,
            "bootID": "01234567-89ab-cdef-8123-456789abcdef", "state": "awaitingConfiguration"]
        } else if operation == "status" {
          data = ["profile": "standard", "state": "awaitingConfiguration",
            "bootID": "01234567-89ab-cdef-8123-456789abcdef", "uplink": NSNull(),
            "authorizationActive": false, "networkdActive": false, "singBoxActive": false,
            "baselineActive": true, "ready": false, "activeOperation": NSNull()]
        } else {
          data = ["egress": ["curlIP": "1.1.1.1", "chromiumIP": "1.1.1.1",
            "isp": "unexpected", "country": "ZZ"], "doh": NSNull(), "checks": []]
        }
        let response = try JSONSerialization.data(withJSONObject: [
          "schemaVersion": 2, "requestID": requestID, "ok": true, "data": data])
        try BoundedJSONFrameCodec.write(BoundedJSONFrameCodec.encodePayload(response), to: pair.guest)
      }
    }
    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host, label: "test.nativecontainers.agent.standard-mismatch"
    ) { Darwin.close(pair.host) }
    let client = LinuxVirtualMachineAgentClient(transport: transport)
    _ = try await client.establish(descriptor: descriptor, timeoutSeconds: 5)
    await #expect(throws: LinuxVirtualMachineAgentClientError.protocolViolation("the verification result has inconsistent proxy fields")) {
      _ = try await client.verify(profile: .standard, timeoutSeconds: 5)
    }
    await client.close()
    try await guest.value
  }

  @Test
  func boundedTransportTimesOutWithoutAFrame() async throws {
    let pair = try SocketPair()
    defer { Darwin.close(pair.guest) }
    let transport = try POSIXLinuxVirtualMachineAgentTransport(
      descriptor: pair.host,
      label: "test.nativecontainers.agent.timeout"
    ) {
      Darwin.close(pair.host)
    }
    await #expect(throws: LinuxVirtualMachineAgentTransportError.timedOut) {
      _ = try await transport.readFrame(timeout: .milliseconds(10))
    }
    transport.close()
  }

  private func trustedDescriptor() throws -> LinuxBoxDescriptor {
    try LinuxBoxDescriptor(
      imageID: "nativecontainers-debian-13-arm64-v1",
      imageBuildRevision: "linux-box-image-v1",
      rawImageSHA512: String(repeating: "a", count: 128)
    )
  }
}

private struct SocketPair: @unchecked Sendable {
  let host: Int32
  let guest: Int32

  init() throws {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw LinuxVirtualMachineAgentTransportError.configurationFailed(errno)
    }
    host = descriptors[0]
    guest = descriptors[1]
  }
}
