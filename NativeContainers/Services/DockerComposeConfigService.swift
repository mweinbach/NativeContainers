import CryptoKit
import Foundation

protocol ComposeConfigRendering: Sendable {
  func render(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeRenderedConfiguration
}

struct DockerComposeConfigService: ComposeConfigRendering {
  private let composeClient: any DockerComposeClientInstalling
  private let commandExecutor: any HostCommandExecuting
  private let environment: [String: String]

  init(
    composeClient: any DockerComposeClientInstalling,
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(
      launcher: FoundationHostProcessLauncher(maximumOutputBytes: 4 * 1_024 * 1_024)
    ),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.composeClient = composeClient
    self.commandExecutor = commandExecutor
    environment = Self.controlledEnvironment(from: processEnvironment)
  }

  func render(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeRenderedConfiguration {
    try Self.validate(options)
    let executableURL = try await composeClient.verifiedExecutableURL()
    let full = try await renderModel(
      executableURL: executableURL,
      source: source,
      options: options,
      profiles: ["*"]
    )
    let active = try await renderModel(
      executableURL: executableURL,
      source: source,
      options: options,
      profiles: options.profiles
    )
    return ComposeRenderedConfiguration(
      fullConfiguration: full,
      activeConfiguration: active,
      fullConfigurationSHA256: Self.sha256(full),
      activeConfigurationSHA256: Self.sha256(active),
      composeReleaseVersion: composeClient.release.version
    )
  }

  private func renderModel(
    executableURL: URL,
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    profiles: [String]
  ) async throws -> Data {
    var arguments = [
      "--project-name",
      options.projectName,
      "--project-directory",
      source.directoryURL.nativeContainersPOSIXPath,
      "--file",
      source.composeFileURL.nativeContainersPOSIXPath,
    ]
    for profile in profiles {
      arguments.append(contentsOf: ["--profile", profile])
    }
    arguments.append(contentsOf: [
      "config",
      "--format",
      "json",
      "--no-env-resolution",
    ])

    let result = try await commandExecutor.execute(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: .seconds(30)
    )
    guard !result.outputWasTruncated else {
      throw ComposeProjectLifecycleError.configOutputTruncated
    }
    guard result.exitCode == 0 else {
      throw ComposeProjectLifecycleError.configCommandFailed(
        exitCode: result.exitCode,
        output: "The canonical model could not be rendered."
      )
    }
    return try Self.normalizedJSON(
      result.standardOutput,
      expectedProjectName: options.projectName
    )
  }

  private static func normalizedJSON(
    _ value: String,
    expectedProjectName: String
  ) throws -> Data {
    guard let data = value.data(using: .utf8) else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The output was not valid UTF-8."
      )
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The output was not valid JSON."
      )
    }
    guard
      let dictionary = object as? [String: Any],
      let projectName = dictionary["name"] as? String,
      projectName == expectedProjectName,
      dictionary["services"] is [String: Any]
    else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The project name or services model did not match the review."
      )
    }
    do {
      return try JSONSerialization.data(
        withJSONObject: dictionary,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical JSON could not be normalized."
      )
    }
  }

  private static func validate(_ options: ComposeProjectReviewOptions) throws {
    guard isValidComposeProjectName(options.projectName) else {
      throw ComposeProjectLifecycleError.invalidProjectName(options.projectName)
    }
    for profile in options.profiles where !isValidComposeProfileName(profile) {
      throw ComposeProjectLifecycleError.invalidProfileName(profile)
    }
  }

  private static func controlledEnvironment(
    from source: [String: String]
  ) -> [String: String] {
    let allowedKeys = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR"]
    var result = source.filter { allowedKeys.contains($0.key) }
    result["COMPOSE_DISABLE_ENV_FILE"] = "true"
    result["COMPOSE_MENU"] = "false"
    result["COMPOSE_ANSI"] = "never"
    result["NO_COLOR"] = "1"
    return result
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
