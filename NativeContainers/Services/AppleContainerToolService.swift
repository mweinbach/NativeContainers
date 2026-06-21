import ContainerAPIClient
import ContainerizationExtras
import Darwin
import Foundation

actor AppleContainerToolService: ContainerTooling {
  private static let maximumCommandOutputBytes = 1_024 * 1_024

  private let containerClient: ContainerClient

  init(containerClient: ContainerClient = ContainerClient()) {
    self.containerClient = containerClient
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) async throws -> ContainerCommandResult {
    let snapshot = try await containerClient.get(id: id)
    guard snapshot.status == .running else {
      throw ContainerToolValidationError.containerNotRunning(id)
    }

    var configuration = snapshot.configuration.initProcess
    configuration.executable = request.executable
    configuration.arguments = request.arguments
    configuration.terminal = false
    configuration.environment = try Parser.allEnv(
      imageEnvs: configuration.environment,
      envFiles: [],
      envs: request.environment.map(\.entry)
    )
    if let workingDirectory = request.workingDirectory {
      configuration.workingDirectory = workingDirectory
    }

    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    let process = try await containerClient.createProcess(
      containerId: id,
      processId: UUID().uuidString.lowercased(),
      configuration: configuration,
      stdio: [nil, standardOutputPipe.fileHandleForWriting, standardErrorPipe.fileHandleForWriting]
    )
    let standardOutputTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardOutputPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let standardErrorTask = Task.detached(priority: .utility) {
      try Self.readBoundedOutput(
        from: standardErrorPipe.fileHandleForReading,
        maximumBytes: Self.maximumCommandOutputBytes
      )
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
      try await process.start()
      try standardOutputPipe.fileHandleForWriting.close()
      try standardErrorPipe.fileHandleForWriting.close()
      let exitCode = try await AppleContainerToolProcessWaiter.wait(
        for: AppleContainerCommandProcess(process: process),
        timeoutSeconds: request.timeoutSeconds
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

  func copyIntoContainer(id: String, source: URL, destination: String) async throws {
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
      throw ContainerToolValidationError.invalidLocalURL
    }
    try await containerClient.copyIn(
      id: id,
      source: source.path(percentEncoded: false),
      destination: destination,
      createParents: true
    )
  }

  func copyFromContainer(id: String, source: String, destination: URL) async throws {
    var destination = destination.standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(
      atPath: destination.path(percentEncoded: false),
      isDirectory: &isDirectory
    ), isDirectory.boolValue {
      destination.append(path: URL(filePath: source).lastPathComponent)
    }
    try await containerClient.copyOut(
      id: id,
      source: source,
      destination: destination.path(percentEncoded: false),
      createParents: true
    )
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

private struct AppleContainerCommandProcess: RuntimeManagedProcess {
  let process: any ClientProcess

  func wait() async throws -> Int32 {
    try await process.wait()
  }

  func kill(_ signal: Int32) async throws {
    try await process.kill(signal)
  }
}

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
