import ContainerResource
import Darwin
import Foundation

protocol RuntimeCommandExecuting: Sendable {
  func execute(
    in containerID: String,
    configuration: ProcessConfiguration,
    timeoutSeconds: Int
  ) async throws -> ContainerCommandResult
}

actor AppleRuntimeCommandExecutor: RuntimeCommandExecuting {
  static let defaultMaximumOutputBytes = 1_024 * 1_024

  private let processClient: any AppleRuntimeProcessCreating
  private let maximumOutputBytes: Int

  init(
    processClient: any AppleRuntimeProcessCreating = AppleContainerProcessXPCClient(),
    maximumOutputBytes: Int = defaultMaximumOutputBytes
  ) {
    precondition(maximumOutputBytes > 0)
    self.processClient = processClient
    self.maximumOutputBytes = maximumOutputBytes
  }

  func execute(
    in containerID: String,
    configuration: ProcessConfiguration,
    timeoutSeconds: Int
  ) async throws -> ContainerCommandResult {
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    let process = try await processClient.createRuntimeProcess(
      containerID: containerID,
      processID: UUID().uuidString.lowercased(),
      configuration: configuration,
      standardIO: [
        nil,
        standardOutputPipe.fileHandleForWriting,
        standardErrorPipe.fileHandleForWriting,
      ]
    )
    let outputLimit = maximumOutputBytes
    let standardOutputTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardOutputPipe.fileHandleForReading,
        maximumBytes: outputLimit
      )
    }
    let standardErrorTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardErrorPipe.fileHandleForReading,
        maximumBytes: outputLimit
      )
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
      try await process.start()
      try? standardOutputPipe.fileHandleForWriting.close()
      try? standardErrorPipe.fileHandleForWriting.close()
      let exitCode = try await AppleContainerToolProcessWaiter.wait(
        for: process,
        timeoutSeconds: timeoutSeconds
      )
      let standardOutput = try await standardOutputTask.value
      let standardError = try await standardErrorTask.value
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      return ContainerCommandResult(
        exitCode: exitCode,
        standardOutput: String(decoding: standardOutput.data, as: UTF8.self),
        standardError: String(decoding: standardError.data, as: UTF8.self),
        outputWasTruncated: standardOutput.isTruncated || standardError.isTruncated,
        duration: startedAt.duration(to: clock.now)
      )
    } catch {
      try? await process.kill(SIGKILL)
      try? standardOutputPipe.fileHandleForWriting.close()
      try? standardErrorPipe.fileHandleForWriting.close()
      try? standardOutputPipe.fileHandleForReading.close()
      try? standardErrorPipe.fileHandleForReading.close()
      standardOutputTask.cancel()
      standardErrorTask.cancel()
      throw error
    }
  }

  private static func readBoundedOutput(
    from handle: FileHandle,
    maximumBytes: Int
  ) throws -> (data: Data, isTruncated: Bool) {
    var result = Data()
    var isTruncated = false
    while !Task.isCancelled {
      guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
      if chunk.count >= maximumBytes {
        result = Data(chunk.suffix(maximumBytes))
        isTruncated = true
      } else {
        let excess = result.count + chunk.count - maximumBytes
        if excess > 0 {
          result.removeFirst(excess)
          isTruncated = true
        }
        result.append(chunk)
      }
    }
    return (result, isTruncated)
  }
}

typealias ContainerCommandProcess = RuntimeManagedProcess

enum AppleContainerToolProcessWaiter {
  static func wait(
    for process: any RuntimeManagedProcess,
    timeoutSeconds: Int,
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) async throws -> Int32 {
    do {
      return try await RuntimeProcessWaiter.wait(
        for: process,
        timeoutSeconds: timeoutSeconds,
        sleep: sleep
      )
    } catch RuntimeProcessWaitError.timedOut {
      throw ContainerToolValidationError.commandTimedOut(timeoutSeconds)
    }
  }
}
