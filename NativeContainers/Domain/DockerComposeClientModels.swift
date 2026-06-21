import Foundation

struct DockerComposeRelease: Equatable, Sendable {
  let version: String
  let binaryURL: URL
  let binarySHA256: String
  let provenanceURL: URL
  let provenanceSHA256: String
  let provenanceSubjectName: String
  let sourceURI: String
  let sourceRevision: String
  let buildType: String
  let builderID: String
  let maximumBinaryByteCount: Int64
  let maximumProvenanceByteCount: Int64

  static let pinned = DockerComposeRelease(
    version: "5.1.4",
    binaryURL: URL(
      string:
        "https://github.com/docker/compose/releases/download/v5.1.4/docker-compose-darwin-aarch64"
    )!,
    binarySHA256: "4cad7fc67dd089a598a15598ad38d04e6f23bf299846d26b2c572f1f96a7c49f",
    provenanceURL: URL(
      string:
        "https://github.com/docker/compose/releases/download/v5.1.4/docker-compose-darwin-aarch64.provenance.json"
    )!,
    provenanceSHA256:
      "983374926035c526e8dedb590b18c3cb43f47b31c39a75df8c98d61ceb662d18",
    provenanceSubjectName: "docker-compose-darwin-aarch64",
    sourceURI: "https://github.com/docker/compose.git#refs/tags/v5.1.4",
    sourceRevision: "6ce6411902e8e3c9be91be0c572b2441486357f7",
    buildType:
      "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
    builderID: "https://github.com/docker/compose/actions/runs/26170360055/attempts/1",
    maximumBinaryByteCount: 40 * 1_024 * 1_024,
    maximumProvenanceByteCount: 1 * 1_024 * 1_024
  )
}

enum DockerComposeClientInstallationState: Equatable, Sendable {
  case notInstalled
  case ready(version: String)
  case invalid(reason: String)
}

struct DockerComposeClientSnapshot: Equatable, Sendable {
  let release: DockerComposeRelease
  let installation: DockerComposeClientInstallationState
  let executableURL: URL
  let provenanceURL: URL
}

enum DockerComposeClientError: LocalizedError, Equatable, Sendable {
  case downloadResponse(artifact: String, status: Int)
  case artifactTooLarge(artifact: String, byteCount: Int64)
  case unsafeInstallLocation(String)
  case binaryDigestMismatch
  case provenanceDigestMismatch
  case binaryArchitectureInvalid
  case provenanceInvalid(String)
  case incompleteInstallation
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .downloadResponse(let artifact, let status):
      "Docker Compose \(artifact) download returned HTTP status \(status)."
    case .artifactTooLarge(let artifact, let byteCount):
      "The Docker Compose \(artifact) is unexpectedly large (\(byteCount) bytes)."
    case .unsafeInstallLocation(let path):
      "The private Docker Compose install location is missing or unsafe: \(path)"
    case .binaryDigestMismatch:
      "The Docker Compose binary does not match the pinned SHA-256 digest."
    case .provenanceDigestMismatch:
      "The Docker Compose provenance does not match the pinned SHA-256 digest."
    case .binaryArchitectureInvalid:
      "The Docker Compose binary is not the pinned thin arm64 Mach-O artifact."
    case .provenanceInvalid(let reason):
      "The Docker Compose provenance is invalid: \(reason)"
    case .incompleteInstallation:
      "The private Docker Compose installation is incomplete. Reinstall it."
    case .unavailable(let reason):
      "Docker Compose installation is unavailable: \(reason)"
    }
  }
}
