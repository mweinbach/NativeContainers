import ContainerResource
import ContainerXPC
import Foundation

protocol LinuxMachineProvisioningProcess: RuntimeManagedProcess {
  func start() async throws
}

protocol LinuxMachineProcessCreating: Sendable {
  func createProcess(
    containerID: String,
    processID: String,
    configuration: ProcessConfiguration
  ) async throws -> any LinuxMachineProvisioningProcess
}

struct AppleContainerProcessXPCClient: LinuxMachineProcessCreating {
  private let mutationSender: any AppleXPCRequestSending
  private let waitSender: any AppleXPCRequestSending
  private let signalSender: any AppleXPCRequestSending

  init(
    mutationTimeout: Duration = .seconds(10),
    waitTimeout: Duration = .seconds(35),
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
    let request = XPCMessage(route: .containerCreateProcess)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    request.set(key: .processConfig, value: try JSONEncoder().encode(configuration))
    _ = try await mutationSender.send(
      request,
      operation: "Create Linux machine setup process"
    )
    return AppleContainerXPCProcess(
      containerID: containerID,
      processID: processID,
      mutationSender: mutationSender,
      waitSender: waitSender,
      signalSender: signalSender
    )
  }
}

private struct AppleContainerXPCProcess: LinuxMachineProvisioningProcess {
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
      operation: "Start Linux machine setup process"
    )
  }

  func wait() async throws -> Int32 {
    let request = XPCMessage(route: .containerWait)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    let response = try await waitSender.send(
      request,
      operation: "Wait for Linux machine setup process"
    )
    return Int32(response.int64(key: .exitCode))
  }

  func kill(_ signal: Int32) async throws {
    let request = XPCMessage(route: .containerKill)
    request.set(key: .id, value: containerID)
    request.set(key: .processIdentifier, value: processID)
    request.set(key: .signal, value: Int64(signal))
    _ = try await signalSender.send(
      request,
      operation: "KILL Linux machine setup process"
    )
  }
}
