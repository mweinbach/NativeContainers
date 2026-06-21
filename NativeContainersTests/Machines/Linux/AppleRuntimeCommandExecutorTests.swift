import ContainerResource
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple runtime command executor")
struct AppleRuntimeCommandExecutorTests {
  @Test
  func capturesSeparateBoundedOutputAndPreservesNonzeroExit() async throws {
    let processClient = RecordingRuntimeProcessClient(
      standardOutput: Data("prefix-stdout".utf8),
      standardError: Data("prefix-stderr".utf8),
      exitCode: 7
    )
    let executor = AppleRuntimeCommandExecutor(
      processClient: processClient,
      maximumOutputBytes: 6
    )
    let configuration = ProcessConfiguration(
      executable: "/bin/example",
      arguments: ["one"],
      environment: ["PATH=/usr/bin"],
      workingDirectory: "/work"
    )

    let result = try await executor.execute(
      in: "runtime-id",
      configuration: configuration,
      timeoutSeconds: 5
    )

    #expect(result.exitCode == 7)
    #expect(result.standardOutput == "stdout")
    #expect(result.standardError == "stderr")
    #expect(result.outputWasTruncated)
    #expect(await processClient.containerIDs == ["runtime-id"])
    #expect(await processClient.configurations.map(\.executable) == ["/bin/example"])
    #expect(await processClient.standardIOPresence == [[false, true, true]])
  }

  @Test
  func cancellationKillsTheCreatedProcess() async {
    let processClient = RecordingRuntimeProcessClient(
      standardOutput: Data(),
      standardError: Data(),
      exitCode: nil
    )
    let executor = AppleRuntimeCommandExecutor(processClient: processClient)
    let configuration = ProcessConfiguration(
      executable: "/bin/sleep",
      arguments: ["60"],
      environment: []
    )
    let operation = Task {
      try await executor.execute(
        in: "runtime-id",
        configuration: configuration,
        timeoutSeconds: 60
      )
    }

    while !(await processClient.process.hasStartedWaiting) {
      await Task.yield()
    }
    operation.cancel()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
    while (await processClient.process.killSignals).isEmpty {
      await Task.yield()
    }
    #expect((await processClient.process.killSignals).allSatisfy { $0 == SIGKILL })
  }
}

private actor RecordingRuntimeProcessClient: AppleRuntimeProcessCreating {
  let process: RecordingRuntimeProcess
  private(set) var containerIDs: [String] = []
  private(set) var configurations: [ProcessConfiguration] = []
  private(set) var standardIOPresence: [[Bool]] = []

  init(standardOutput: Data, standardError: Data, exitCode: Int32?) {
    process = RecordingRuntimeProcess(
      standardOutput: standardOutput,
      standardError: standardError,
      exitCode: exitCode
    )
  }

  func createRuntimeProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration,
    standardIO: [FileHandle?]
  ) async -> any AppleRuntimeProcess {
    containerIDs.append(containerID)
    configurations.append(configuration)
    standardIOPresence.append(standardIO.map { $0 != nil })
    await process.attach(
      standardOutput: standardIO.indices.contains(1) ? standardIO[1] : nil,
      standardError: standardIO.indices.contains(2) ? standardIO[2] : nil
    )
    return process
  }
}

private actor RecordingRuntimeProcess: AppleRuntimeProcess {
  private let output: Data
  private let error: Data
  private let exitCode: Int32?
  private var outputHandle: FileHandle?
  private var errorHandle: FileHandle?
  private var waitContinuation: CheckedContinuation<Int32, any Error>?
  private(set) var hasStartedWaiting = false
  private(set) var killSignals: [Int32] = []

  init(standardOutput: Data, standardError: Data, exitCode: Int32?) {
    output = standardOutput
    error = standardError
    self.exitCode = exitCode
  }

  func attach(standardOutput: FileHandle?, standardError: FileHandle?) {
    outputHandle = standardOutput
    errorHandle = standardError
  }

  func start() throws {
    try outputHandle?.write(contentsOf: output)
    try errorHandle?.write(contentsOf: error)
  }

  func wait() async throws -> Int32 {
    hasStartedWaiting = true
    if let exitCode {
      return exitCode
    }
    return try await withCheckedThrowingContinuation { continuation in
      waitContinuation = continuation
    }
  }

  func kill(_ signal: Int32) {
    killSignals.append(signal)
    waitContinuation?.resume(returning: 128 + signal)
    waitContinuation = nil
  }

  func resize(to size: ContainerTerminalSize) {}
}
