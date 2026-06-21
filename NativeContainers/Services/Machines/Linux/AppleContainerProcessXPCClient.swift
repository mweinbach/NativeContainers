import ContainerResource
import ContainerXPC
import Darwin
import Foundation

protocol LinuxMachineProvisioningProcess: RuntimeManagedProcess {
  func start() async throws
}

protocol AppleRuntimeProcess: LinuxMachineProvisioningProcess, ContainerTerminalProcess {}

protocol AppleRuntimeProcessCreating: Sendable {
  func createRuntimeProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration,
    standardIO: [FileHandle?]
  ) async throws -> any AppleRuntimeProcess
}

protocol LinuxMachineProcessCreating: Sendable {
  func createProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration
  ) async throws -> any LinuxMachineProvisioningProcess
}

struct AppleContainerProcessXPCClient: LinuxMachineProcessCreating, AppleRuntimeProcessCreating {
  private let mutationSender: any AppleXPCRequestSending
  private let waitSender: any AppleXPCRequestSending
  private let signalSender: any AppleXPCRequestSending

  init(
    mutationTimeout: Duration = .seconds(10),
    waitTimeout: Duration? = nil,
    signalTimeout: Duration = .seconds(2)
  ) {
    mutationSender = AppleXPCRequestClient(operationTimeout: mutationTimeout)
    waitSender = AppleXPCRequestClient(operationTimeout: waitTimeout)
    signalSender = AppleXPCRequestClient(operationTimeout: signalTimeout)
  }

  init(
    mutationSender: any AppleXPCRequestSending,
    waitSender: any AppleXPCRequestSending,
    signalSender: any AppleXPCRequestSending
  ) {
    self.mutationSender = mutationSender
    self.waitSender = waitSender
    self.signalSender = signalSender
  }

  func createProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration
  ) async throws -> any LinuxMachineProvisioningProcess {
    try await createRuntimeProcess(
      containerID: containerID,
      processID: processID,
      configuration: configuration,
      standardIO: []
    )
  }

  func createRuntimeProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration,
    standardIO: [FileHandle?]
  ) async throws -> any AppleRuntimeProcess {
    let request = XPCMessage(route: .containerCreateProcess)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    request.set(key: .processConfig, value: try JSONEncoder().encode(configuration))
    for (index, handle) in standardIO.enumerated() {
      switch index {
      case 0:
        if let handle {
          request.set(key: .stdin, value: try duplicateForTransfer(handle))
        }
      case 1:
        if let handle {
          request.set(key: .stdout, value: try duplicateForTransfer(handle))
        }
      case 2:
        if let handle {
          request.set(key: .stderr, value: try duplicateForTransfer(handle))
        }
      default:
        throw AppleRuntimeProcessError.invalidStandardIOIndex(index)
      }
    }
    let process = AppleContainerXPCProcess(
      containerID: containerID,
      processID: processID,
      mutationSender: mutationSender,
      waitSender: waitSender,
      signalSender: signalSender
    )
    do {
      _ = try await mutationSender.send(
        request,
        operation: "Create runtime process"
      )
      return process
    } catch {
      // A lost create reply is outcome-uncertain. Address the same process ID once and
      // best-effort KILL it without inheriting caller cancellation; never create or run a retry.
      await Task.detached {
        try? await process.kill(SIGKILL)
      }.value
      throw error
    }
  }

  private func duplicateForTransfer(_ handle: FileHandle) throws -> FileHandle {
    let descriptor = Darwin.dup(handle.fileDescriptor)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // XPCMessage.set takes ownership by closing this descriptor after wrapping it.
    // Keep the caller's original FileHandle valid until its normal lifecycle closes it.
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  }
}

private struct AppleContainerXPCProcess: AppleRuntimeProcess {
  let containerID: String
  let processID: String
  let mutationSender: any AppleXPCRequestSending
  let waitSender: any AppleXPCRequestSending
  let signalSender: any AppleXPCRequestSending

  func start() async throws {
    let request = XPCMessage(route: .containerStartProcess)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    _ = try await mutationSender.send(
      request,
      operation: "Start runtime process"
    )
  }

  func wait() async throws -> Int32 {
    let request = XPCMessage(route: .containerWait)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    let response = try await waitSender.send(
      request,
      operation: "Wait for runtime process"
    )
    return Int32(response.int64(key: .exitCode))
  }

  func kill(_ signal: Int32) async throws {
    let request = XPCMessage(route: .containerKill)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    // The pinned 1.0 server decodes this field as a signal string even though its
    // high-level ClientProcess currently encodes an integer.
    request.set(key: .signal, value: String(signal))
    _ = try await signalSender.send(
      request,
      operation: "Signal runtime process"
    )
  }

  func resize(to size: ContainerTerminalSize) async throws {
    let request = XPCMessage(route: .containerResize)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    request.set(key: .width, value: UInt64(size.columns))
    request.set(key: .height, value: UInt64(size.rows))
    _ = try await signalSender.send(
      request,
      operation: "Resize runtime process terminal"
    )
  }
}

enum AppleRuntimeProcessError: LocalizedError, Equatable {
  case invalidStandardIOIndex(Int)

  var errorDescription: String? {
    switch self {
    case .invalidStandardIOIndex(let index):
      "Standard I/O index \(index) is invalid."
    }
  }
}
