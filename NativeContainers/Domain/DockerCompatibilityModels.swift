import Foundation

struct SocktainerRelease: Equatable, Sendable {
  let version: String
  let sourceURL: URL
  let sha256: String
  let developerTeamIdentifier: String
  let maximumByteCount: Int64

  static let pinned = SocktainerRelease(
    version: "1.0.0",
    sourceURL: URL(
      string:
        "https://github.com/socktainer/socktainer/releases/download/v1.0.0/socktainer"
    )!,
    sha256: "8e41e8a75aaf9cb2fa938a7493bbc504d93bfbd14fbf09826d4c57d2150bd020",
    developerTeamIdentifier: "HYSCB8KRL2",
    maximumByteCount: 80 * 1_024 * 1_024
  )
}

enum SocktainerInstallationState: Equatable, Sendable {
  case notInstalled
  case ready(version: String)
  case invalid(reason: String)
}

enum AppleContainerCompatibilityState: Equatable, Sendable {
  case compatible(version: String)
  case unavailable(reason: String)
  case incompatible(foundVersion: String, requiredVersion: String)
}

enum SocktainerRuntimeState: Equatable, Sendable {
  case stopped
  case starting
  case running(processID: Int32)
  case stopping
  case blockedByForeignSocket(URL)
  case failed(String)
}

struct DockerContextSnapshot: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case dockerUnavailable
    case missing
    case ready
    case drifted(actualEndpoint: String)
    case failed(String)
  }

  let state: State
  let activeContext: String?
  let environmentOverrides: [String]
}

struct DockerCompatibilitySnapshot: Equatable, Sendable {
  let release: SocktainerRelease
  let installation: SocktainerInstallationState
  let appleContainer: AppleContainerCompatibilityState
  let runtime: SocktainerRuntimeState
  let dockerContext: DockerContextSnapshot
  let socketURL: URL

  static func initial(
    release: SocktainerRelease = .pinned,
    socketURL: URL
  ) -> DockerCompatibilitySnapshot {
    DockerCompatibilitySnapshot(
      release: release,
      installation: .notInstalled,
      appleContainer: .unavailable(reason: "Not checked"),
      runtime: .stopped,
      dockerContext: DockerContextSnapshot(
        state: .dockerUnavailable,
        activeContext: nil,
        environmentOverrides: []
      ),
      socketURL: socketURL
    )
  }
}

enum DockerCompatibilityError: LocalizedError, Equatable, Sendable {
  case downloadResponse(Int)
  case artifactTooLarge(Int64)
  case artifactDigestMismatch
  case artifactSignatureInvalid
  case artifactSignerMismatch
  case unsafeInstallLocation(String)
  case installationRequired
  case incompatibleAppleContainer(found: String, required: String)
  case appleContainerUnavailable(String)
  case processAlreadyRunning
  case processNotOwned
  case foreignSocket(URL)
  case processLaunchFailed(String)
  case processExitedDuringStartup(String)
  case processStartupTimedOut
  case processDidNotExitAfterKill
  case dockerUnavailable
  case dockerContextInspectionFailed(String)
  case dockerContextMutationFailed(String)
  case dockerActiveContextChanged(before: String?, after: String?)

  var errorDescription: String? {
    switch self {
    case .downloadResponse(let status):
      "Socktainer download returned HTTP status \(status)."
    case .artifactTooLarge(let byteCount):
      "The downloaded Socktainer artifact is unexpectedly large (\(byteCount) bytes)."
    case .artifactDigestMismatch:
      "The downloaded Socktainer artifact does not match the pinned SHA-256 digest."
    case .artifactSignatureInvalid:
      "The downloaded Socktainer artifact does not have a valid trusted code signature."
    case .artifactSignerMismatch:
      "The downloaded Socktainer artifact is not signed by the pinned developer team."
    case .unsafeInstallLocation(let path):
      "The Socktainer install location is missing or unsafe: \(path)"
    case .installationRequired:
      "Install the pinned Socktainer release before starting Docker compatibility."
    case .incompatibleAppleContainer(let found, let required):
      "Socktainer requires Apple container \(required), but \(found) is installed."
    case .appleContainerUnavailable(let reason):
      "Apple container could not be validated: \(reason)"
    case .processAlreadyRunning:
      "The app-owned Socktainer process is already running."
    case .processNotOwned:
      "No app-owned Socktainer process is available to stop."
    case .foreignSocket(let url):
      "Another process owns or left the Socktainer socket at \(url.path(percentEncoded: false))."
    case .processLaunchFailed(let reason):
      "Socktainer could not be launched: \(reason)"
    case .processExitedDuringStartup(let output):
      "Socktainer exited before its socket became ready.\(output.isEmpty ? "" : " " + output)"
    case .processStartupTimedOut:
      "Socktainer did not create its socket before the startup timeout."
    case .processDidNotExitAfterKill:
      "Socktainer did not confirm exit after SIGKILL."
    case .dockerUnavailable:
      "Docker CLI was not found in a supported installation location."
    case .dockerContextInspectionFailed(let reason):
      "The nativecontainers Docker context could not be inspected: \(reason)"
    case .dockerContextMutationFailed(let reason):
      "The nativecontainers Docker context could not be updated: \(reason)"
    case .dockerActiveContextChanged(let before, let after):
      "Docker's active context changed unexpectedly from \(before ?? "none") to \(after ?? "none")."
    }
  }
}
