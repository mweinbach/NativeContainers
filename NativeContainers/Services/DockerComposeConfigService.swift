import CryptoKit
import Foundation

struct ComposeCommandEnvironment: Equatable, Sendable {
  let values: [String: String]
  let sha256: String

  init(processEnvironment: [String: String]) {
    let allowedKeys = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR"]
    var values = processEnvironment.filter { allowedKeys.contains($0.key) }
    values["COMPOSE_DISABLE_ENV_FILE"] = "true"
    values["COMPOSE_MENU"] = "false"
    values["COMPOSE_ANSI"] = "never"
    values["NO_COLOR"] = "1"
    self.values = values
    var data = Data()
    for key in values.keys.sorted(by: composeStringOrder) {
      data.append(contentsOf: key.utf8)
      data.append(0)
      data.append(contentsOf: values[key, default: ""].utf8)
      data.append(0)
    }
    sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

protocol ComposeConfigRendering: Sendable {
  var commandEnvironment: ComposeCommandEnvironment { get }

  func render(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeRenderedConfiguration
}

protocol ComposeExecutionToolResolving: Sendable {
  var commandEnvironment: ComposeCommandEnvironment { get }
  func verifiedExecutableURL() async throws -> URL
}

struct UnavailableComposeExecutionToolResolver: ComposeExecutionToolResolving {
  let commandEnvironment = ComposeCommandEnvironment(processEnvironment: [:])

  func verifiedExecutableURL() async throws -> URL {
    throw ComposeProjectLifecycleError.unavailable(
      "No verified Docker Compose execution tool is configured."
    )
  }
}

struct DockerComposeConfigService: ComposeConfigRendering {
  let commandEnvironment: ComposeCommandEnvironment

  private let composeClient: any DockerComposeClientInstalling
  private let commandExecutor: any HostCommandExecuting

  init(
    composeClient: any DockerComposeClientInstalling,
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(
      launcher: FoundationHostProcessLauncher(maximumOutputBytes: 4 * 1_024 * 1_024)
    ),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.composeClient = composeClient
    self.commandExecutor = commandExecutor
    commandEnvironment = ComposeCommandEnvironment(processEnvironment: processEnvironment)
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
    let serviceHashes = try await renderServiceHashes(
      executableURL: executableURL,
      source: source,
      options: options
    )
    return ComposeRenderedConfiguration(
      fullConfiguration: full,
      activeConfiguration: active,
      fullConfigurationSHA256: Self.sha256(full),
      activeConfigurationSHA256: Self.sha256(active),
      composeReleaseVersion: composeClient.release.version,
      composeBinarySHA256: composeClient.release.binarySHA256,
      composeSourceRevision: composeClient.release.sourceRevision,
      environmentSHA256: commandEnvironment.sha256,
      serviceConfigurationHashes: serviceHashes
    )
  }

  private func renderModel(
    executableURL: URL,
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    profiles: [String]
  ) async throws -> Data {
    var arguments = baseArguments(source: source, options: options)
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
      environment: commandEnvironment.values,
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
    guard result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Docker Compose emitted diagnostics while rendering the canonical model."
      )
    }
    return try Self.normalizedJSON(
      result.standardOutput,
      expectedProjectName: options.projectName
    )
  }

  private func renderServiceHashes(
    executableURL: URL,
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) async throws -> [String: String] {
    var arguments = baseArguments(source: source, options: options)
    arguments.append(contentsOf: ["--profile", "*", "config", "--hash", "*"])
    let result = try await commandExecutor.execute(
      executableURL: executableURL,
      arguments: arguments,
      environment: commandEnvironment.values,
      timeout: .seconds(30)
    )
    guard !result.outputWasTruncated else {
      throw ComposeProjectLifecycleError.configOutputTruncated
    }
    guard result.exitCode == 0 else {
      throw ComposeProjectLifecycleError.configCommandFailed(
        exitCode: result.exitCode,
        output: "The service configuration hashes could not be rendered."
      )
    }
    guard result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Docker Compose emitted diagnostics while hashing service configuration."
      )
    }
    return try Self.parseServiceHashes(result.standardOutput)
  }

  private func baseArguments(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions
  ) -> [String] {
    [
      "--project-name",
      options.projectName,
      "--project-directory",
      source.directoryURL.nativeContainersPOSIXPath,
      "--file",
      source.composeFileURL.nativeContainersPOSIXPath,
    ]
  }

  private static func parseServiceHashes(_ output: String) throws -> [String: String] {
    var hashes: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 2 else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "A service configuration hash row was malformed."
        )
      }
      let service = String(fields[0])
      let hash = String(fields[1])
      guard
        hashes[service] == nil,
        hash.count == 64,
        hash.utf8.allSatisfy({
          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        })
      else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "A service configuration hash was invalid or duplicated."
        )
      }
      hashes[service] = hash
    }
    guard !hashes.isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "No service configuration hashes were returned."
      )
    }
    return hashes
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

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension DockerComposeConfigService: ComposeExecutionToolResolving {
  func verifiedExecutableURL() async throws -> URL {
    try await composeClient.verifiedExecutableURL()
  }
}
