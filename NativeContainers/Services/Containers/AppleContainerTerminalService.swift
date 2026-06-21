import Foundation

actor AppleContainerTerminalService: ContainerTerminalOpening {
  private let shellDiscovery: any ContainerShellDiscovering
  private let terminalProcessLauncher: any ContainerTerminalProcessLaunching

  init(
    shellDiscovery: any ContainerShellDiscovering = AppleContainerShellService(),
    terminalProcessLauncher: any ContainerTerminalProcessLaunching =
      AppleContainerTerminalProcessLauncher()
  ) {
    self.shellDiscovery = shellDiscovery
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

    let executable: String
    switch request.program {
    case .preferredShell:
      executable = try await shellDiscovery.discoverShell(in: id).executable
    case .executable(let requestedExecutable):
      executable = requestedExecutable
    }
    let resolvedRequest = try ResolvedContainerTerminalRequest(
      request: request,
      executable: executable
    )

    let transport = PipeContainerTerminalTransport()
    do {
      let process = try await terminalProcessLauncher.makeProcess(
        containerID: id,
        request: resolvedRequest,
        standardInput: transport.childStandardInput,
        standardOutput: transport.childStandardOutput
      )

      let session = AppleContainerTerminalSession(
        process: process,
        transport: transport,
        maximumRetainedOutputBytes: resolvedRequest.maximumRetainedOutputBytes
      )
      try await session.start(initialSize: resolvedRequest.initialSize)
      return session
    } catch {
      transport.closeAll()
      throw error
    }
  }
}
