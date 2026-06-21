import Foundation

protocol ComposeUpCommandExecuting: Sendable {
  func validate(_ request: ComposeProjectMutationRequest) async throws
  func execute(_ request: ComposeProjectMutationRequest) async throws
}

struct ComposeUpCommandService: ComposeUpCommandExecuting {
  private let commandExecutor: any HostCommandExecuting
  private let executionWorkspace: any ComposeExecutionWorkspaceManaging
  private let executionOverlay: any ComposeExecutionOverlayPreparing
  private let serviceHashDecoder: any ComposeServiceHashDecoding

  init(
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(
      launcher: FoundationHostProcessLauncher(maximumOutputBytes: 1_024 * 1_024)
    ),
    executionWorkspace: any ComposeExecutionWorkspaceManaging =
      FileComposeExecutionWorkspace(),
    executionOverlay: any ComposeExecutionOverlayPreparing =
      ComposeExecutionOverlayService(),
    serviceHashDecoder: any ComposeServiceHashDecoding = ComposeServiceHashDecoder()
  ) {
    self.commandExecutor = commandExecutor
    self.executionWorkspace = executionWorkspace
    self.executionOverlay = executionOverlay
    self.serviceHashDecoder = serviceHashDecoder
  }

  func validate(_ request: ComposeProjectMutationRequest) async throws {
    let prepared = try prepare(request)
    var arguments = prepared.baseArguments
    arguments.append(contentsOf: ["--profile", "*", "config", "--hash", "*"])
    let result = try await executeCommand(
      request: request,
      lease: prepared.lease,
      arguments: arguments,
      timeout: .seconds(30)
    )
    guard result.exitCode == 0, !result.outputWasTruncated else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The execution overlay service hashes could not be verified."
      )
    }
    guard result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Docker Compose emitted diagnostics while verifying the execution overlay."
      )
    }
    let hashes = try serviceHashDecoder.decode(result.standardOutput)
    guard hashes == request.plan.serviceConfigurationHashes else {
      throw ComposeProjectLifecycleError.stalePlan
    }
  }

  func execute(_ request: ComposeProjectMutationRequest) async throws {
    let prepared = try prepare(request)
    var arguments = prepared.baseArguments
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

    let result = try await executeCommand(
      request: request,
      lease: prepared.lease,
      arguments: arguments,
      timeout: .seconds(600)
    )
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

  private func prepare(
    _ request: ComposeProjectMutationRequest
  ) throws -> (
    lease: ComposeExecutionConfigurationLease,
    baseArguments: [String]
  ) {
    let configuration = try executionOverlay.prepare(
      canonicalConfiguration: request.canonicalConfiguration,
      plan: request.plan
    )
    let lease = try executionWorkspace.prepare(
      operationID: request.operationID,
      projectName: request.plan.options.projectName,
      canonicalConfiguration: configuration.data,
      expectedSHA256: configuration.sha256
    )
    return (
      lease,
      [
        "--context", DockerContextService.contextName,
        "--project-name", request.plan.options.projectName,
        "--project-directory", lease.directoryURL.nativeContainersPOSIXPath,
        "--file", lease.configurationURL.nativeContainersPOSIXPath,
      ]
    )
  }

  private func executeCommand(
    request: ComposeProjectMutationRequest,
    lease: ComposeExecutionConfigurationLease,
    arguments: [String],
    timeout: Duration
  ) async throws -> HostCommandResult {
    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: request.composeExecutableURL,
        arguments: arguments,
        environment: request.commandEnvironment.values,
        timeout: timeout
      )
    } catch {
      let commandError = error
      do {
        try executionWorkspace.release(lease)
      } catch {
        throw ComposeProjectLifecycleError.partialCompletion(
          "Compose execution failed and its immutable configuration also failed revalidation: \(error.localizedDescription)"
        )
      }
      throw commandError
    }
    try executionWorkspace.release(lease)
    return result
  }
}
