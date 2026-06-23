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
    for profile in request.plan.options.profiles {
      arguments.append(contentsOf: ["--profile", profile])
    }
    arguments.append(contentsOf: ["config", "--hash", "*"])
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
    let activeNames = Set(request.plan.desiredState.activeServiceNames)
    let expected = request.plan.executionServiceConfigurationHashes.filter {
      activeNames.contains($0.key)
    }
    guard hashes == expected, Set(expected.keys) == activeNames else {
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
    ])
    if !request.plan.containerActions.contains(where: {
      $0.operation == .replace || $0.operation == .scaleDown
    }) {
      arguments.append("--no-recreate")
    }

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
        output: request.reviewedInputs.containsSensitiveValues
          ? "Compose diagnostics were suppressed because the operation contains reviewed inputs."
          : result.outputWasTruncated
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
    let stagedFileURLs: [String: URL]
    if request.reviewedInputs.files.isEmpty {
      stagedFileURLs = [:]
    } else {
      guard let inputStager = executionWorkspace as? any ComposeExecutionInputStaging else {
        throw ComposeProjectLifecycleError.unavailable(
          "The configured Compose execution workspace cannot stage reviewed inputs."
        )
      }
      stagedFileURLs = try inputStager.stageInputs(
        projectName: request.plan.options.projectName,
        files: request.reviewedInputs.files
      )
    }
    let configuration = try executionOverlay.prepare(
      canonicalConfiguration: request.canonicalConfiguration,
      plan: request.plan,
      reviewedInputs: request.reviewedInputs,
      stagedFileURLs: stagedFileURLs
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
        environment: request.commandEnvironment.values.merging(
          request.reviewedInputs.environmentValues,
          uniquingKeysWith: { base, _ in base }
        ),
        timeout: timeout
      )
    } catch {
      let commandError = error
      do {
        try revalidateInputs(request)
        try executionWorkspace.release(lease)
      } catch {
        throw ComposeProjectLifecycleError.partialCompletion(
          "Compose execution failed and its immutable configuration also failed revalidation: \(error.localizedDescription)"
        )
      }
      if request.reviewedInputs.containsSensitiveValues {
        throw ComposeProjectLifecycleError.commandFailed(
          action: .up,
          exitCode: -1,
          output:
            "Compose process diagnostics were suppressed because the operation contains reviewed inputs."
        )
      }
      throw commandError
    }
    try revalidateInputs(request)
    try executionWorkspace.release(lease)
    return result
  }

  private func revalidateInputs(_ request: ComposeProjectMutationRequest) throws {
    guard !request.reviewedInputs.files.isEmpty else { return }
    guard let inputStager = executionWorkspace as? any ComposeExecutionInputStaging else {
      throw ComposeProjectLifecycleError.workspaceUnsafe(
        "The reviewed Compose input store became unavailable."
      )
    }
    _ = try inputStager.stageInputs(
      projectName: request.plan.options.projectName,
      files: request.reviewedInputs.files
    )
  }
}
