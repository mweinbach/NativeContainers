import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple container process XPC client")
struct AppleContainerProcessXPCClientTests {
  @Test
  func sendsCreateStartWaitResizeAndKillThroughFocusedTransports() async throws {
    let sender = RecordingProcessXPCSender()
    let client = AppleContainerProcessXPCClient(
      mutationSender: sender,
      waitSender: sender,
      signalSender: sender
    )
    let configuration = ProcessConfiguration(
      executable: "/sbin/machine/init",
      arguments: ["-u"],
      environment: ["PATH=/usr/bin"],
      terminal: false
    )

    let input = Pipe()
    let output = Pipe()
    defer {
      try? input.fileHandleForReading.close()
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
    }
    let process = try await client.createRuntimeProcess(
      containerID: "machine-runtime",
      processID: "setup",
      configuration: configuration,
      standardIO: [input.fileHandleForReading, output.fileHandleForWriting, nil]
    )
    #expect(fcntl(input.fileHandleForReading.fileDescriptor, F_GETFD) >= 0)
    #expect(fcntl(output.fileHandleForWriting.fileDescriptor, F_GETFD) >= 0)
    try await process.start()
    try await process.resize(to: try ContainerTerminalSize(columns: 132, rows: 43))
    let exitCode = try await process.wait()
    try await process.kill(SIGKILL)

    #expect(exitCode == 0)
    #expect(
      await sender.routes == [
        XPCRoute.containerCreateProcess.rawValue,
        XPCRoute.containerStartProcess.rawValue,
        XPCRoute.containerResize.rawValue,
        XPCRoute.containerWait.rawValue,
        XPCRoute.containerKill.rawValue,
      ]
    )
    #expect(await sender.identifiers == Array(repeating: "machine-runtime/setup", count: 5))
    #expect(await sender.createdStandardIO == [true, true, false])
    #expect(await sender.terminalSizes == ["132x43"])
    #expect(await sender.signals == [String(SIGKILL)])
  }

  @Test
  func rejectsMoreThanThreeStandardIOHandlesBeforeSending() async {
    let sender = RecordingProcessXPCSender()
    let client = AppleContainerProcessXPCClient(
      mutationSender: sender,
      waitSender: sender,
      signalSender: sender
    )
    let configuration = ProcessConfiguration(
      executable: "/bin/true",
      arguments: [],
      environment: []
    )

    await #expect(throws: AppleRuntimeProcessError.invalidStandardIOIndex(3)) {
      try await client.createRuntimeProcess(
        containerID: "machine-runtime",
        processID: "invalid-stdio",
        configuration: configuration,
        standardIO: [nil, nil, nil, nil]
      )
    }
    #expect(await sender.routes.isEmpty)
  }

  @Test
  func uncertainCreateReplyBestEffortKillsOnlyTheSameProcessID() async {
    let signalSender = RecordingProcessXPCSender()
    let client = AppleContainerProcessXPCClient(
      mutationSender: FailingProcessXPCSender(),
      waitSender: signalSender,
      signalSender: signalSender
    )
    let configuration = ProcessConfiguration(
      executable: "/bin/true",
      arguments: [],
      environment: []
    )

    await #expect(throws: ProcessXPCSenderError.replyLost) {
      try await client.createRuntimeProcess(
        containerID: "machine-runtime",
        processID: "one-shot-id",
        configuration: configuration,
        standardIO: []
      )
    }

    #expect(await signalSender.routes == [XPCRoute.containerKill.rawValue])
    #expect(await signalSender.identifiers == ["machine-runtime/one-shot-id"])
    #expect(await signalSender.signals == [String(SIGKILL)])
  }
}

private enum ProcessXPCSenderError: Error, Equatable {
  case replyLost
}

private struct FailingProcessXPCSender: AppleXPCRequestSending {
  func send(_ message: XPCMessage, operation: String) throws -> XPCMessage {
    throw ProcessXPCSenderError.replyLost
  }
}

private actor RecordingProcessXPCSender: AppleXPCRequestSending {
  private(set) var routes: [String] = []
  private(set) var identifiers: [String] = []
  private(set) var signals: [String] = []
  private(set) var createdStandardIO: [Bool] = []
  private(set) var terminalSizes: [String] = []

  func send(_ message: XPCMessage, operation: String) -> XPCMessage {
    let route = message.string(key: XPCMessage.routeKey) ?? ""
    routes.append(route)
    identifiers.append(
      "\(message.string(key: .id) ?? "")/\(message.string(key: .processIdentifier) ?? "")"
    )
    if route == XPCRoute.containerKill.rawValue {
      signals.append(message.string(key: .signal) ?? "")
    }
    if route == XPCRoute.containerCreateProcess.rawValue {
      createdStandardIO = [
        message.fileHandle(key: .stdin) != nil,
        message.fileHandle(key: .stdout) != nil,
        message.fileHandle(key: .stderr) != nil,
      ]
    }
    if route == XPCRoute.containerResize.rawValue {
      terminalSizes.append(
        "\(message.uint64(key: .width))x\(message.uint64(key: .height))"
      )
    }

    let response = XPCMessage(route: "testReply")
    response.set(key: .exitCode, value: Int64(0))
    return response
  }
}
