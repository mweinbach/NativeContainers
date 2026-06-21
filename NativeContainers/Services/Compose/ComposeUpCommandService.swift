import Foundation

protocol ComposeUpCommandExecuting: Sendable {
  func execute(_ request: ComposeProjectMutationRequest) async throws
}

struct ComposeUpCommandService: ComposeUpCommandExecuting {
  private let commandExecutor: any HostCommandExecuting
  private let executionWorkspace: any ComposeExecutionWorkspaceManaging

  init(
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(
      launcher: FoundationHostProcessLauncher(maximumOutputBytes: 1_024 * 1_024)
    ),
    executionWorkspace: any ComposeExecutionWorkspaceManaging =
      FileComposeExecutionWorkspace()
  ) {
    self.commandExecutor = commandExecutor
    self.executionWorkspace = executionWorkspace
  }

  func execute(_ request: ComposeProjectMutationRequest) async throws {
    let lease = try executionWorkspace.prepare(
      operationID: request.operationID,
      canonicalConfiguration: request.canonicalConfiguration,
      expectedSHA256: request.plan.fullConfigurationSHA256
    )
    var arguments = [
      "--context", DockerContextService.contextName,
      "--project-name", request.plan.options.projectName,
      "--project-directory", lease.directoryURL.nativeContainersPOSIXPath,
      "--file", lease.configurationURL.nativeContainersPOSIXPath,
    ]
    for profile in request.plan.options.profiles {
      arguments.append(contentsOf: ["--profile", profile])
    }
    arguments.append(contentsOf: [
      "up",
      "--detach",
      "--no-build",
      "--pull", request.plan.options.pullPolicy.rawValue,
      "--no-recreate",
    ])

    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: request.composeExecutableURL,
        arguments: arguments,
        environment: request.commandEnvironment.values,
        timeout: .seconds(600)
      )
    } catch {
      let commandError = error
      do {
        try executionWorkspace.remove(lease)
      } catch {
        throw ComposeProjectLifecycleError.partialCompletion(
          "Compose execution failed and its private workspace also could not be removed: \(error.localizedDescription)"
        )
      }
      throw commandError
    }
    try executionWorkspace.remove(lease)
    guard result.exitCode == 0, !result.outputWasTruncated else {
      throw ComposeProjectLifecycleError.commandFailed(
        action: .up,
        exitCode: result.exitCode,
        output: result.outputWasTruncated
          ? "Compose output exceeded the bounded execution log."
          : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
