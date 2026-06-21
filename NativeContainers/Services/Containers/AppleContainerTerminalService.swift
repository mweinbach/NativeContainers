import Foundation

actor AppleContainerTerminalService: ContainerTerminalOpening {
  private let terminalProcessLauncher: any ContainerTerminalProcessLaunching

  init(
    terminalProcessLauncher: any ContainerTerminalProcessLaunching =
      AppleContainerTerminalProcessLauncher()
  ) {
    self.terminalProcessLauncher = terminalProcessLauncher
  }

  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw ContainerTerminalError.invalidContainerIdentifier
    }

    let transport = PipeContainerTerminalTransport()
    do {
      let process = try await terminalProcessLauncher.makeProcess(
        containerID: id,
        request: request,
        standardInput: transport.childStandardInput,
        standardOutput: transport.childStandardOutput
      )

      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: request.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: request.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }
}
