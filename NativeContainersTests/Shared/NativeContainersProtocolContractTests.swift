import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct NativeContainersProtocolContractTests {
  @Test
  func boundedFrameReadConsumesExactlyOneFrame() throws {
    let pipe = Pipe()
    let payload = Data("{\"ok\":true}".utf8)
    let frame = try BoundedJSONFrameCodec.encodePayload(payload)
    try pipe.fileHandleForWriting.write(contentsOf: frame + Data([0xa5, 0x5a]))

    let decoded = try BoundedJSONFrameCodec.readPayload(
      from: pipe.fileHandleForReading.fileDescriptor
    )
    var sentinel = [UInt8](repeating: 0, count: 2)
    let count = Darwin.read(
      pipe.fileHandleForReading.fileDescriptor,
      &sentinel,
      sentinel.count
    )

    #expect(decoded == payload)
    #expect(count == 2)
    #expect(sentinel == [0xa5, 0x5a])
  }

  @Test
  func controlRequestUsesCanonicalEnvelopeAndExactPayload() throws {
    let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let request = try NativeContainersControlRequest(
      requestID: requestID,
      operation: .create,
      timeoutSeconds: 1_800,
      payload: .create(
        LinuxBoxCreatePayload(
          name: "Residential Box",
          cpuCount: 4,
          memoryBytes: 8 * 1_073_741_824,
          diskBytes: 32 * 1_073_741_824
        )
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(request)
    let decoded = try NativeContainersControlRequest.decodeStrict(data)

    #expect(decoded == request)
    #expect(String(decoding: data, as: UTF8.self).contains(requestID.uuidString.lowercased()))
  }

  @Test(arguments: [
    "{\"schemaVersion\":1,\"schemaVersion\":1,\"requestID\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"operation\":\"linux-box.list\",\"timeoutSeconds\":30,\"payload\":{}}",
    "{\"schemaVersion\":1,\"requestID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"operation\":\"linux-box.list\",\"timeoutSeconds\":30,\"payload\":{}}",
    "{\"schemaVersion\":1,\"requestID\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"operation\":\"linux-box.unknown\",\"timeoutSeconds\":30,\"payload\":{}}",
    "{\"schemaVersion\":1,\"requestID\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"operation\":\"linux-box.list\",\"timeoutSeconds\":4,\"payload\":{}}",
    "{\"schemaVersion\":1,\"requestID\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"operation\":\"linux-box.list\",\"timeoutSeconds\":30,\"payload\":{\"extra\":true}}",
    "{\"schemaVersion\":1,\"requestID\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"operation\":\"linux-box.list\",\"timeoutSeconds\":30,\"payload\":{},\"extra\":true}"
  ])
  func strictControlDecoderRejectsNoncanonicalDocuments(document: String) {
    #expect(throws: (any Error).self) {
      _ = try NativeContainersControlRequest.decodeStrict(Data(document.utf8))
    }
  }

  @Test
  func guestHelloRequiresCanonicalPaddedThirtyTwoByteChallenge() throws {
    let challenge = Data(repeating: 0xa5, count: 32)
    let request = try LinuxBoxGuestRequest(
      requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      operation: .hello,
      timeoutSeconds: 60,
      payload: .hello(LinuxBoxGuestHelloPayload(challenge: CanonicalBase64(challenge)))
    )
    let data = try JSONEncoder().encode(request)
    #expect(try LinuxBoxGuestRequest.decodeStrict(data) == request)

    let valid = challenge.base64EncodedString()
    let invalid = valid.hasSuffix("=") ? String(valid.dropLast()) : valid + "="
    let document = "{\"schemaVersion\":2,\"requestID\":\"11111111-2222-3333-4444-555555555555\",\"operation\":\"hello\",\"timeoutSeconds\":60,\"payload\":{\"challenge\":\"\(invalid)\"}}"
    #expect(throws: (any Error).self) {
      _ = try LinuxBoxGuestRequest.decodeStrict(Data(document.utf8))
    }
  }

  @Test
  func responseRequestIdentifierMustMatch() throws {
    let request = try NativeContainersControlRequest(
      requestID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
      operation: .list,
      timeoutSeconds: 30,
      payload: .empty
    )
    #expect(throws: StrictJSONError.self) {
      try request.validateResponseRequestID(
        CanonicalUUID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
      )
    }
  }
  @Test
  func guestStatusUsesCanonicalSchemaTwoKeysAndPreservesNullableValues() throws {
    let result = LinuxBoxGuestStatusResult(
      profile: .standard,
      state: .awaitingConfiguration,
      bootID: CanonicalUUID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
      uplink: nil,
      authorizationActive: false,
      networkdActive: false,
      singBoxActive: false,
      baselineActive: true,
      ready: false,
      activeOperation: nil
    )
    let data = try JSONEncoder().encode(result)
    let object = try StrictJSONDocument.parse(data).object(exactKeys: [
      "profile", "state", "bootID", "uplink", "authorizationActive",
      "networkdActive", "singBoxActive", "baselineActive", "ready", "activeOperation"
    ])

    #expect(object["profile"]?.string == LinuxBoxProfile.standard.rawValue)
    #expect(object["uplink"] == StrictJSONValue.null)
    #expect(object["activeOperation"] == StrictJSONValue.null)
    #expect(try JSONDecoder().decode(LinuxBoxGuestStatusResult.self, from: data) == result)
  }

  @Test
  func guestStatusRejectsUnknownSchemaTwoKey() throws {
    let document = """
      {"profile":"standard","state":"awaitingConfiguration","bootID":"11111111-2222-3333-4444-555555555555","uplink":null,"authorizationActive":false,"networkdActive":false,"singBoxActive":false,"baselineActive":true,"ready":false,"activeOperation":null,"extra":true}
      """

    #expect(throws: StrictJSONError.self) {
      try StrictJSONDocument.parse(Data(document.utf8)).object(exactKeys: [
        "profile", "state", "bootID", "uplink", "authorizationActive",
        "networkdActive", "singBoxActive", "baselineActive", "ready", "activeOperation"
      ])
    }
  }

}
