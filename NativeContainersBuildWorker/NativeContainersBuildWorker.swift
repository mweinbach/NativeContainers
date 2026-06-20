import Darwin
import Foundation

@main
struct NativeContainersBuildWorker {
  static func main() async {
    let writer = ContainerBuildWorkerEventWriter(handle: .standardOutput)
    do {
      try await writer.send(.hello())
      let input = FileHandle.standardInput
      let request = try readRequest(from: input)
      monitorParentLifetime(input)
      let runner = ContainerBuildWorkerRunner(writer: writer)
      try await runner.run(request)
    } catch {
      let failure: ContainerBuildWorkerFailure
      if let workerError = error as? ContainerBuildWorkerError {
        failure = workerError.failure
      } else {
        failure = ContainerBuildWorkerFailure(
          code: "unexpected",
          message: error.localizedDescription,
          buildID: nil,
          partialImageDigest: nil
        )
      }
      try? await writer.send(.failed(failure))
      exit(EXIT_FAILURE)
    }
  }

  private static func readRequest(from handle: FileHandle) throws -> ContainerBuildWorkerRequest {
    try ContainerBuildWorkerFramedInput.readOne(
      from: handle.fileDescriptor,
      as: ContainerBuildWorkerRequest.self
    )
  }

  private static func monitorParentLifetime(_ handle: FileHandle) {
    let lease = ContainerBuildWorkerInputLease(handle: handle)
    Task.detached(priority: .background) {
      lease.waitForEndOfFile()
      Darwin._exit(EXIT_FAILURE)
    }
  }
}

actor ContainerBuildWorkerEventWriter {
  private let handle: FileHandle
  private let encoder = JSONEncoder()

  init(handle: FileHandle) {
    self.handle = handle
  }

  func send(_ event: ContainerBuildWorkerEvent) throws {
    let data = try ContainerBuildWorkerFrameCodec.encode(event, using: encoder)
    try handle.write(contentsOf: data)
  }
}

private final class ContainerBuildWorkerInputLease: @unchecked Sendable {
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func waitForEndOfFile() {
    _ = handle.readDataToEndOfFile()
  }
}

struct ContainerBuildWorkerError: LocalizedError, Sendable {
  let failure: ContainerBuildWorkerFailure

  var errorDescription: String? { failure.message }

  static func make(
    code: String,
    message: String,
    buildID: UUID? = nil,
    partialImageDigest: String? = nil
  ) -> ContainerBuildWorkerError {
    ContainerBuildWorkerError(
      failure: ContainerBuildWorkerFailure(
        code: code,
        message: message,
        buildID: buildID,
        partialImageDigest: partialImageDigest
      )
    )
  }
}
