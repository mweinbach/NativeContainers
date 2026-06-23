import ContainerAPIClient
import Darwin
import Foundation
import MachineAPIClient

enum AppleContainerRuntimeDistributionContract {
  static let requiredVersion = "1.0.0"
  static let packageIdentifier = "com.apple.container-installer"
  static let executableURL = URL(filePath: "/usr/local/bin/container")
  static let releaseURL = URL(
    string: "https://github.com/apple/container/releases/tag/1.0.0"
  )!
}

protocol AppleContainerRuntimeSettingUp: Sendable {
  func start() async throws
}

protocol AppleContainerInstalledRuntimeStarting: Sendable {
  func startInstalledRuntime() async throws
}

protocol AppleContainerRuntimeProbing: Sendable {
  func probe() async throws -> AppleContainerRuntimeObservation
}

protocol AppleContainerExecutableValidating: Sendable {
  func validate(executableURL: URL) throws
}

struct AppleContainerRuntimeObservation: Equatable, Sendable {
  let version: String
}

enum AppleContainerRuntimeSetupError: LocalizedError, Equatable, Sendable {
  case executableMissing(String)
  case executableUnsafe(String)
  case executableSignatureInvalid
  case executableSignerMismatch
  case incompatibleVersion(found: String, required: String)
  case versionCheckFailed(String)
  case startFailed(String)
  case verificationFailed(String)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .executableMissing(let path):
      "Apple container \(Self.requiredVersion) is not installed at \(path). Install Apple's signed package, then try again."
    case .executableUnsafe(let path):
      "The Apple container executable is missing or unsafe at \(path)."
    case .executableSignatureInvalid:
      "The Apple container executable does not have a valid trusted code signature."
    case .executableSignerMismatch:
      "The container executable is not the reviewed Apple-signed product."
    case .incompatibleVersion(let found, let required):
      "NativeContainers requires Apple container \(required), but \(found) is installed."
    case .versionCheckFailed(let detail):
      "Apple container version validation failed. \(detail)"
    case .startFailed(let detail):
      "Apple container setup failed. \(detail)"
    case .verificationFailed(let detail):
      "Apple container services did not become ready. \(detail)"
    case .unavailable:
      "Apple container setup is unavailable in this build."
    }
  }

  private static let requiredVersion = AppleContainerRuntimeSetupService.requiredVersion
}

struct LiveAppleContainerRuntimeProbe: AppleContainerRuntimeProbing {
  func probe() async throws -> AppleContainerRuntimeObservation {
    let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
    _ = try await MachineClient().list()
    guard
      let version = AppleContainerRuntimeSetupService.semanticVersion(
        in: health.apiServerVersion
      )
    else {
      throw AppleContainerRuntimeSetupError.verificationFailed(
        "The API server returned an unknown version."
      )
    }
    return AppleContainerRuntimeObservation(version: version)
  }
}

struct SignedAppleContainerExecutableValidator: AppleContainerExecutableValidating {
  static let teamIdentifier = "UPBK2H6LZM"
  static let signingIdentifier = "com.apple.container.cli"

  func validate(executableURL: URL) throws {
    let path = executableURL.standardizedFileURL.path(percentEncoded: false)
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw AppleContainerRuntimeSetupError.executableMissing(path)
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == 0,
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_mode & mode_t(S_IXUSR) != 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw AppleContainerRuntimeSetupError.executableUnsafe(path)
    }

    let requirement =
      "anchor apple generic and identifier \"\(Self.signingIdentifier)\" "
      + "and certificate leaf[subject.OU] = \"\(Self.teamIdentifier)\""
    do {
      try StaticCodeRequirementValidator().validate(
        codeAt: executableURL,
        requirement: requirement
      )
    } catch StaticCodeRequirementValidationError.requirementFailed {
      throw AppleContainerRuntimeSetupError.executableSignerMismatch
    } catch StaticCodeRequirementValidationError.requirementCreationFailed {
      throw AppleContainerRuntimeSetupError.executableSignerMismatch
    } catch {
      throw AppleContainerRuntimeSetupError.executableSignatureInvalid
    }
  }
}

actor AppleContainerRuntimeSetupService:
  AppleContainerRuntimeSettingUp,
  AppleContainerInstalledRuntimeStarting
{
  static let requiredVersion = AppleContainerRuntimeDistributionContract.requiredVersion
  static let defaultExecutableURL = AppleContainerRuntimeDistributionContract.executableURL

  private let executableURL: URL
  private let validator: any AppleContainerExecutableValidating
  private let probe: any AppleContainerRuntimeProbing
  private let commandExecutor: any HostCommandExecuting
  private let setupTimeout: Duration

  init(
    executableURL: URL = AppleContainerRuntimeSetupService.defaultExecutableURL,
    validator: any AppleContainerExecutableValidating =
      SignedAppleContainerExecutableValidator(),
    probe: any AppleContainerRuntimeProbing = LiveAppleContainerRuntimeProbe(),
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    setupTimeout: Duration = .seconds(30 * 60)
  ) {
    self.executableURL = executableURL
    self.validator = validator
    self.probe = probe
    self.commandExecutor = commandExecutor
    self.setupTimeout = setupTimeout
  }

  func start() async throws {
    do {
      try await probeAndValidate()
      return
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleContainerRuntimeSetupError {
      switch error {
      case .incompatibleVersion, .verificationFailed:
        throw error
      default:
        break
      }
    } catch {
      // An unreachable service is the expected reason to enter the setup path.
    }

    try await startInstalledRuntime()
    do {
      try await probeAndValidate()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleContainerRuntimeSetupError {
      throw error
    } catch {
      throw AppleContainerRuntimeSetupError.verificationFailed(
        error.localizedDescription
      )
    }
  }

  func startInstalledRuntime() async throws {
    try validator.validate(executableURL: executableURL)
    try await validateInstalledVersion()

    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: executableURL,
        arguments: ["system", "start", "--enable-kernel-install"],
        environment: nil,
        timeout: setupTimeout
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AppleContainerRuntimeSetupError.startFailed(error.localizedDescription)
    }
    guard result.exitCode == 0 else {
      throw AppleContainerRuntimeSetupError.startFailed(Self.commandDetail(result))
    }
  }

  private func probeAndValidate() async throws {
    let running = try await probe.probe()
    try validate(version: running.version)
  }

  private func validateInstalledVersion() async throws {
    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: executableURL,
        arguments: ["--version"],
        environment: nil,
        timeout: .seconds(10)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AppleContainerRuntimeSetupError.versionCheckFailed(error.localizedDescription)
    }
    guard result.exitCode == 0 else {
      throw AppleContainerRuntimeSetupError.versionCheckFailed(Self.commandDetail(result))
    }
    let output = result.standardOutput + "\n" + result.standardError
    guard let version = Self.semanticVersion(in: output) else {
      throw AppleContainerRuntimeSetupError.versionCheckFailed(
        "The signed CLI returned an unknown version."
      )
    }
    try validate(version: version)
  }

  private func validate(version: String) throws {
    guard version == Self.requiredVersion else {
      throw AppleContainerRuntimeSetupError.incompatibleVersion(
        found: version,
        required: Self.requiredVersion
      )
    }
  }

  nonisolated static func semanticVersion(in value: String) -> String? {
    value
      .split { character in
        !character.isNumber && character != "."
      }
      .map(String.init)
      .first { token in
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { Int($0) != nil }
      }
  }

  private nonisolated static func commandDetail(_ result: HostCommandResult) -> String {
    let output = [result.standardError, result.standardOutput]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let status = "The signed CLI exited with status \(result.exitCode)."
    let detail = String(output.suffix(2_000))
    let truncation = result.outputWasTruncated ? " Output was truncated." : ""
    guard !detail.isEmpty else { return status + truncation }
    return status + truncation + " " + detail
  }
}

struct UnavailableAppleContainerRuntimeSetupService: AppleContainerRuntimeSettingUp {
  func start() async throws {
    throw AppleContainerRuntimeSetupError.unavailable
  }
}
